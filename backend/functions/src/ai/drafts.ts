import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import type {
  AIWorkflow,
  AssistantChatResult,
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
