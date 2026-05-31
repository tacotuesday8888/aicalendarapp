import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";

import {
  deleteImportSchema,
  importCommitSchema,
  importFileRequestSchema,
  importTextRequestSchema
} from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { db, normalizeFirestoreValue, serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import { aiFunctionOptions } from "../shared/functionOptions.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";
import { logLegacyAIEndpointUse } from "../shared/legacyInstrumentation.js";
import { runAIWorkflow } from "../ai/router.js";
import { authorizeAndReserveAIUsage, enforceAIPremiumAccess, logAIUsage } from "../ai/usage.js";

type ImportCourseRecord = {
  id: string;
  title: string;
  instructor: string;
  meetingDays: string[];
  colorHex: string;
};

type ImportAssignmentRecord = {
  id: string;
  courseID: string | null;
  title: string;
  dueDate: string | null;
  notes: string;
  isComplete: boolean;
};

export const importSyllabusText = onAuthenticatedJsonRequest(importTextRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("importSyllabusText", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await authorizeAndReserveAIUsage(userID, "syllabus_import");

  return createImportJob(userID, data.text, "text-import");
}, aiFunctionOptions);

export const importSyllabusFile = onAuthenticatedJsonRequest(importFileRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("importSyllabusFile", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await enforceAIPremiumAccess(userID, "syllabus_import");

  const extractedText = (data.extractedText ?? "").trim();

  if (!extractedText) {
    return createFailedImportJob(
      userID,
      data.sourceName,
      data.uploadedPath ?? null,
      "No readable syllabus text was extracted from the selected file."
    );
  }

  await authorizeAndReserveAIUsage(userID, "syllabus_import");
  return createImportJob(userID, extractedText, data.sourceName, data.uploadedPath ?? null);
}, aiFunctionOptions);

export const commitImportJob = onAuthenticatedJsonRequest(importCommitSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const imports = userScopedCollection(userID, "imports");
  const importRef = imports.doc(data.job.id);
  const importSnapshot = await importRef.get();

  if (!importSnapshot.exists) {
    throw new HttpsError("not-found", "Import job not found.");
  }

  const batch = db.batch();
  const coursesCollection = userScopedCollection(userID, "courses");
  const assignmentsCollection = userScopedCollection(userID, "assignments");
  const storedJob = importSnapshot.data() ?? {};
  const requestedCourses = arrayOfRecords(data.job.extractedCourses);
  const requestedAssignments = arrayOfRecords(data.job.extractedAssignments);
  const useRequestedReview = requestedCourses.length > 0;
  const extractedCourses = sanitizeImportCourses(
    useRequestedReview ? requestedCourses : arrayOfRecords(storedJob.extractedCourses),
    () => coursesCollection.doc().id
  );

  if (!extractedCourses.length) {
    throw new HttpsError("invalid-argument", "Import requires at least one course.");
  }

  const courseIDs = new Set(extractedCourses.map((course) => course.id));
  const extractedAssignments = sanitizeImportAssignments(
    useRequestedReview ? requestedAssignments : arrayOfRecords(storedJob.extractedAssignments),
    () => assignmentsCollection.doc().id,
    courseIDs,
    extractedCourses[0]?.id ?? null
  );

  extractedCourses.forEach((course) => {
    batch.set(coursesCollection.doc(course.id), course, { merge: true });
  });

  extractedAssignments.forEach((assignment) => {
    batch.set(assignmentsCollection.doc(assignment.id), assignment, { merge: true });
  });

  batch.set(
    importRef,
    {
      status: "committed",
      sourceName: stringValue(recordValue(data.job).sourceName) ?? stringValue(storedJob.sourceName) ?? "syllabus-import",
      extractedCourses,
      extractedAssignments,
      warnings: stringArray(recordValue(data.job).warnings, stringArray(storedJob.warnings)),
      uploadedFilePath: storedJob.uploadedFilePath ?? null,
      committedAt: serverTimestamp()
    },
    { merge: true }
  );

  await batch.commit();
  return { success: true };
});

export const deleteImportJob = onAuthenticatedJsonRequest(deleteImportSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const importRef = userScopedCollection(userID, "imports").doc(data.job.id);
  const importSnapshot = await importRef.get();

  if (!importSnapshot.exists) {
    throw new HttpsError("not-found", "Import job not found.");
  }

  const uploadedFilePath = safeUserImportStoragePath(userID, importSnapshot.get("uploadedFilePath"));
  if (uploadedFilePath) {
    try {
      await getStorage().bucket().file(uploadedFilePath).delete();
    } catch {
      // Ignore missing files so metadata cleanup can still complete.
    }
  } else if (importSnapshot.get("uploadedFilePath")) {
    logger.warn("Skipped import file deletion because stored path was outside the user import prefix.", {
      userID,
      importID: data.job.id
    });
  }

  await importRef.delete();
  return { success: true };
});

async function createImportJob(userID: string, rawText: string, sourceName: string, uploadedFilePath: string | null = null) {
  try {
    const response = await runAIWorkflow(userID, {
      workflow: "syllabus_import",
      payload: {
        extractedText: rawText,
        currentDate: new Date().toISOString(),
        timezone: process.env.DEFAULT_TIMEZONE?.trim() || "UTC",
        sourceName,
        uploadedFilePath
      }
    });

    if (!response.draftID) {
      throw new HttpsError("internal", "Syllabus import did not create a review job.");
    }

    const importSnapshot = await userScopedCollection(userID, "imports").doc(response.draftID).get();
    const job = normalizeFirestoreValue(importSnapshot.data() ?? null);
    if (!job || typeof job !== "object" || Array.isArray(job)) {
      throw new HttpsError("internal", "Syllabus import review job could not be loaded.");
    }

    await logAIUsage(userID, "syllabus_import", "success", { sourceName });

    return job;
  } catch (error) {
    await logAIUsage(userID, "syllabus_import", "error", { sourceName }).catch(() => undefined);
    throw error;
  }
}

async function createFailedImportJob(userID: string, sourceName: string, uploadedFilePath: string | null, warning: string) {
  const imports = userScopedCollection(userID, "imports");
  const importRef = imports.doc();

  const job = {
    id: importRef.id,
    sourceName,
    status: "failed",
    extractedCourses: [],
    extractedAssignments: [],
    warnings: [warning],
    uploadedFilePath,
    createdAt: new Date().toISOString(),
    committedAt: null
  };

  await importRef.set({
    ...job,
    createdAt: serverTimestamp()
  });

  return job;
}

function sanitizeID(rawID: unknown): string | null {
  if (typeof rawID !== "string") return null;
  const trimmed = rawID.trim();
  if (
    !trimmed ||
    trimmed === "." ||
    trimmed === ".." ||
    trimmed.toLowerCase() === "undefined" ||
    trimmed.toLowerCase() === "null"
  ) {
    return null;
  }
  // Firestore document IDs cannot contain "/" or be empty; replace risky chars.
  return trimmed.replace(/\//g, "_");
}

function arrayOfRecords(value: unknown): Array<Record<string, unknown>> {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((item): item is Record<string, unknown> => {
    return item !== null && typeof item === "object" && !Array.isArray(item);
  });
}

function recordValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function stringArray(value: unknown, fallback: string[] = []): string[] {
  if (!Array.isArray(value)) {
    return fallback;
  }

  return value
    .map((item) => stringValue(item))
    .filter((item): item is string => Boolean(item));
}

function sanitizeImportCourses(
  courses: Array<Record<string, unknown>>,
  fallbackID: () => string
): ImportCourseRecord[] {
  const usedIDs = new Set<string>();

  return courses
    .map((course) => {
      const title = stringValue(course.title);
      if (!title) {
        return null;
      }

      return {
        id: uniqueDocumentID(sanitizeID(course.id) ?? fallbackID(), usedIDs, fallbackID),
        title,
        instructor: stringValue(course.instructor) ?? "",
        meetingDays: stringArray(course.meetingDays).slice(0, 14),
        colorHex: normalizedColorHex(course.colorHex) ?? "#2F6BFF"
      };
    })
    .filter((course): course is ImportCourseRecord => course !== null);
}

function sanitizeImportAssignments(
  assignments: Array<Record<string, unknown>>,
  fallbackID: () => string,
  validCourseIDs: Set<string>,
  fallbackCourseID: string | null
): ImportAssignmentRecord[] {
  const usedIDs = new Set<string>();

  return assignments
    .map((assignment) => {
      const title = stringValue(assignment.title);
      if (!title) {
        return null;
      }

      const requestedCourseID = sanitizeID(assignment.courseID);
      const courseID = requestedCourseID && validCourseIDs.has(requestedCourseID)
        ? requestedCourseID
        : fallbackCourseID;

      return {
        id: uniqueDocumentID(sanitizeID(assignment.id) ?? fallbackID(), usedIDs, fallbackID),
        courseID,
        title,
        dueDate: normalizedDateString(assignment.dueDate),
        notes: stringValue(assignment.notes) ?? "",
        isComplete: assignment.isComplete === true
      };
    })
    .filter((assignment): assignment is ImportAssignmentRecord => assignment !== null);
}

function uniqueDocumentID(preferredID: string, usedIDs: Set<string>, fallbackID: () => string): string {
  let documentID = preferredID;
  while (usedIDs.has(documentID)) {
    documentID = fallbackID();
  }
  usedIDs.add(documentID);
  return documentID;
}

function normalizedColorHex(value: unknown): string | null {
  const text = stringValue(value);
  if (!text) {
    return null;
  }

  return /^#[0-9A-Fa-f]{6}$/.test(text) ? text.toUpperCase() : null;
}

function normalizedDateString(value: unknown): string | null {
  const text = stringValue(value);
  if (!text) {
    return null;
  }

  const timestamp = Date.parse(text);
  return Number.isNaN(timestamp) ? null : new Date(timestamp).toISOString();
}

function safeUserImportStoragePath(userID: string, value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim().replace(/^\/+/, "");
  const prefix = `users/${userID}/imports/`;
  return trimmed.startsWith(prefix) ? trimmed : null;
}
