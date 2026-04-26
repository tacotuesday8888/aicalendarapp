import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import type {
  AIWorkflow,
  AssistantChatResult,
  GoalPlanGenerationPayload,
  GoalPlanGenerationResult,
  SyllabusImportResult
} from "./schemas.js";

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
