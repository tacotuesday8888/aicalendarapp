import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import type {
  AIWorkflow,
  AssistantChatPayload,
  AssistantChatResult,
  GoalPlanGenerationPayload,
  GoalPlanGenerationResult,
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
