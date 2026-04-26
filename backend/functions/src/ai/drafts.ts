import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import type {
  AIWorkflow,
  AssistantChatPayload,
  AssistantChatResult,
  GoalPlanGenerationPayload,
  GoalPlanGenerationResult,
  SyllabusImportPayload,
  SyllabusImportResult
} from "./schemas.js";

type AssistantDraftRecord = {
  id: string;
  kind: "goalPlan" | "plannerAdjustment" | "sessionEvaluation" | "checkInSummary";
  title: string;
  detail: string;
};

export async function storeReviewDraft(
  userID: string,
  workflow: AIWorkflow,
  result: AssistantChatResult | GoalPlanGenerationResult | SyllabusImportResult
): Promise<string | null> {
  if (workflow === "assistant_chat" && "draftActions" in result && result.draftActions.length === 0) {
    return null;
  }

  const draftRef = userScopedCollection(userID, "aiDrafts").doc();
  await draftRef.set({
    id: draftRef.id,
    workflow,
    status: "pending_review",
    result,
    createdAt: serverTimestamp(),
    committedAt: null
  });

  return draftRef.id;
}

export async function storeGoalPlanReviewDraft(
  userID: string,
  payload: GoalPlanGenerationPayload,
  result: GoalPlanGenerationResult,
  draftID: string
): Promise<void> {
  const draftRef = userScopedCollection(userID, "goalPlans").doc(draftID);

  await draftRef.set({
    id: draftRef.id,
    goalID: payload.goalID ?? "",
    summary: result.summary,
    suggestedTimelineWeeks: payload.timelineWeeks,
    checkpoints: result.milestones.map((milestone, index) => ({
      id: `${draftRef.id}-checkpoint-${index + 1}`,
      title: milestone.title,
      dueDate: milestone.dueDate
    })),
    nextActions: result.nextActions.map((action, index) => ({
      id: `${draftRef.id}-step-${index + 1}`,
      title: action.title,
      isComplete: false
    })),
    createdAt: serverTimestamp()
  });
}

export async function storeAssistantChatReviewState(
  userID: string,
  payload: AssistantChatPayload,
  result: AssistantChatResult,
  draftID: string | null
): Promise<void> {
  const threadRef = userScopedCollection(userID, "assistantThreads").doc("primary");
  const threadSnapshot = await threadRef.get();
  const threadData = threadSnapshot.data() as
    | {
        id?: string;
        messages?: unknown[];
        pendingDrafts?: AssistantDraftRecord[];
      }
    | undefined;
  const timestamp = Date.now();
  const existingMessages = Array.isArray(threadData?.messages) ? threadData.messages : [];
  const existingPendingDrafts = Array.isArray(threadData?.pendingDrafts) ? threadData.pendingDrafts : [];
  const newDrafts = result.draftActions.map((action, index) => ({
    id: assistantDraftArtifactID(draftID, timestamp, index),
    kind: assistantDraftKind(action.type),
    title: action.title,
    detail: action.dueAt ? `${action.reason} Suggested time: ${action.dueAt}` : action.reason
  }));

  await Promise.all([
    threadRef.set(
      {
        id: threadData?.id ?? threadRef.id,
        messages: [
          ...existingMessages,
          {
            id: `${threadRef.id}-user-${timestamp}`,
            role: "user",
            content: payload.message,
            createdAt: new Date(timestamp).toISOString()
          },
          {
            id: `${threadRef.id}-assistant-${timestamp}`,
            role: "assistant",
            content: result.message,
            createdAt: new Date(timestamp).toISOString()
          }
        ],
        pendingDrafts: [...existingPendingDrafts, ...newDrafts],
        createdAt: threadSnapshot.exists ? threadSnapshot.get("createdAt") ?? serverTimestamp() : serverTimestamp(),
        updatedAt: serverTimestamp()
      },
      { merge: true }
    ),
    ...newDrafts.map((draft) =>
      userScopedCollection(userID, "assistantDraftArtifacts").doc(draft.id).set({
        ...draft,
        userID,
        status: "pending",
        sourceThreadID: threadRef.id,
        sourceAIDraftID: draftID,
        createdAt: serverTimestamp()
      })
    )
  ]);
}

export async function storeSyllabusImportReviewJob(
  userID: string,
  payload: SyllabusImportPayload,
  result: SyllabusImportResult
): Promise<string> {
  const importRef = userScopedCollection(userID, "imports").doc();
  const sourceName = payload.sourceName?.trim() || "syllabus-import";
  const courseRecords = result.courses.map((course, index) => {
    const idBase = sanitizeID(course.name) ?? "ai-course";
    const id = `${idBase}-${index + 1}`;
    return {
      id,
      title: course.name,
      instructor: course.instructor ?? "",
      meetingDays: [],
      colorHex: "#2F6BFF"
    };
  });
  const courseIDs = courseRecords.map((course) => course.id);
  const assignmentRecords = result.courses.flatMap((course, courseIndex) => {
    const courseID = courseIDs[courseIndex] ?? null;
    return course.assignments.map((assignment, assignmentIndex) => ({
      id: `${courseID ?? `ai-course-${courseIndex + 1}`}-assignment-${assignmentIndex + 1}`,
      courseID,
      title: assignment.title,
      dueDate: normalizedSyllabusDueDate(assignment.dueDate, assignment.sourceText),
      notes: syllabusAssignmentNotes(assignment),
      isComplete: false
    }));
  });
  const warnings = result.warnings.map((warning) =>
    warning.sourceText ? `${warning.message} Source: ${warning.sourceText}` : warning.message
  );

  await importRef.set({
    id: importRef.id,
    sourceName,
    status: "completed",
    extractedCourses: courseRecords,
    extractedAssignments: assignmentRecords,
    warnings,
    uploadedFilePath: payload.uploadedFilePath ?? null,
    createdAt: serverTimestamp(),
    committedAt: null
  });

  return importRef.id;
}

function assistantDraftArtifactID(draftID: string | null, timestamp: number, index: number): string {
  const baseID = draftID ?? `assistant-${timestamp}`;
  return `${baseID}-action-${index + 1}`;
}

function assistantDraftKind(actionType: string): AssistantDraftRecord["kind"] {
  const normalized = actionType.toLowerCase();

  if (normalized.includes("goal")) {
    return "goalPlan";
  }

  if (normalized.includes("session")) {
    return "sessionEvaluation";
  }

  if (normalized.includes("check") || normalized.includes("vibe") || normalized.includes("reflection")) {
    return "checkInSummary";
  }

  return "plannerAdjustment";
}

function normalizedSyllabusDueDate(value: string | null, sourceText: string): string | null {
  if (!value || Number.isNaN(Date.parse(value))) {
    return null;
  }

  const parsedDate = new Date(value);
  if (isLikelyDateOnlyDueDate(parsedDate, sourceText)) {
    return new Date(
      Date.UTC(parsedDate.getUTCFullYear(), parsedDate.getUTCMonth(), parsedDate.getUTCDate(), 12, 0, 0, 0)
    ).toISOString();
  }

  return parsedDate.toISOString();
}

function isLikelyDateOnlyDueDate(date: Date, sourceText: string): boolean {
  if (sourceTextMentionsTime(sourceText)) {
    return false;
  }

  return (
    date.getUTCHours() === 0 &&
    date.getUTCMinutes() === 0 &&
    date.getUTCSeconds() === 0 &&
    date.getUTCMilliseconds() === 0
  );
}

function sourceTextMentionsTime(sourceText: string): boolean {
  return /\b(?:[01]?\d|2[0-3]):[0-5]\d\b|\b(?:[1-9]|1[0-2])\s*(?:a\.?m\.?|p\.?m\.?)\b/i.test(sourceText);
}

function syllabusAssignmentNotes(assignment: SyllabusImportResult["courses"][number]["assignments"][number]): string {
  const parts = ["Imported from syllabus review.", `Confidence: ${assignment.confidence}.`];
  if (assignment.type) {
    parts.push(`Type: ${assignment.type}.`);
  }
  parts.push(`Source: ${assignment.sourceText}`);
  return parts.join(" ");
}

function sanitizeID(rawID: string): string | null {
  const trimmed = rawID.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return trimmed || null;
}
