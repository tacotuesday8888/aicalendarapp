import { getAuth } from "firebase-admin/auth";
import { getStorage } from "firebase-admin/storage";

import { userJobRequestSchema } from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { db, normalizeFirestoreValue, userDoc, userScopedCollection } from "../shared/firestore.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";

const exportCollections = [
  "onboarding",
  "goals",
  "goalPlans",
  "plannerBlocks",
  "courses",
  "assignments",
  "habits",
  "studySessions",
  "checkIns",
  "vibeChecks",
  "reminderRules",
  "assistantThreads",
  "imports",
  "subscriptions",
  "aiUsageLogs",
  "assistantDraftArtifacts"
];

export const exportUserData = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const profileSnapshot = await userDoc(userID).get();
  const exportedCollections = await Promise.all(
    exportCollections.map(async (collection) => {
      const records = await exportCollection(userID, collection);
      return [collection, records] as const;
    })
  );

  return {
    userID,
    requestedAt: new Date().toISOString(),
    profile: normalizeFirestoreValue(profileSnapshot.data() ?? {}),
    collections: Object.fromEntries(exportedCollections)
  };
});

export const deleteUserAccount = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const uploadedImportFiles = await collectUploadedImportFiles(userID);
  const deletedCollections = await Promise.all(
    exportCollections.map(async (collection) => {
      const deletedCount = await deleteCollection(userID, collection);
      return [collection, deletedCount] as const;
    })
  );

  await Promise.all(
    uploadedImportFiles.map(async (path) => {
      try {
        await getStorage().bucket().file(path).delete();
      } catch {
        // Ignore missing files so account deletion can complete.
      }
    })
  );

  await userDoc(userID).delete().catch(() => undefined);
  await getAuth().deleteUser(userID).catch(() => undefined);

  return {
    success: true,
    userID,
    deletedCollections: Object.fromEntries(deletedCollections),
    deletedUploadedFiles: uploadedImportFiles.length
  };
});

async function exportCollection(userID: string, collection: string) {
  const snapshot = await userScopedCollection(userID, collection).get();
  return snapshot.docs.map((document) => {
    const normalized = normalizeFirestoreValue(document.data());

    if (normalized && typeof normalized === "object" && !Array.isArray(normalized)) {
      return {
        id: document.id,
        ...(normalized as Record<string, unknown>)
      };
    }

    return {
      id: document.id,
      value: normalized
    };
  });
}

async function collectUploadedImportFiles(userID: string): Promise<string[]> {
  const snapshot = await userScopedCollection(userID, "imports").get();
  return snapshot.docs
    .map((document) => {
      const uploadedFilePath = document.data().uploadedFilePath;
      return typeof uploadedFilePath === "string" && uploadedFilePath.length ? uploadedFilePath : null;
    })
    .filter((value): value is string => value !== null);
}

async function deleteCollection(userID: string, collection: string): Promise<number> {
  const snapshot = await userScopedCollection(userID, collection).get();
  const chunks = chunk(snapshot.docs, 400);

  for (const documents of chunks) {
    const batch = db.batch();
    documents.forEach((document) => batch.delete(document.ref));
    await batch.commit();
  }

  return snapshot.size;
}

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];

  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }

  return chunks;
}
