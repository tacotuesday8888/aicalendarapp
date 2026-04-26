import { normalizeFirestoreValue, userScopedCollection } from "../shared/firestore.js";
import type { AssistantChatPayload, GoalPlanGenerationPayload } from "./schemas.js";

export type FirestoreContextDocument = {
  id: string;
  data: unknown;
};

export type AssistantWorkflowContext = {
  timezone: string;
  currentScreen: string | null;
  date: string | null;
  contextHints: Record<string, unknown>;
  goals: FirestoreContextDocument[];
  plannerBlocks: FirestoreContextDocument[];
};

export type GoalPlanWorkflowContext = {
  goal: {
    id: string | null;
    title: string;
    description: string;
  };
};

export async function loadAssistantWorkflowContext(
  userID: string,
  payload: AssistantChatPayload
): Promise<AssistantWorkflowContext> {
  const [goals, plannerBlocks] = await Promise.all([
    loadCollectionPreview(userID, "goals", 8),
    loadCollectionPreview(userID, "plannerBlocks", 12)
  ]);

  return {
    timezone: payload.timezone,
    currentScreen: payload.currentScreen ?? null,
    date: payload.date ?? null,
    contextHints: payload.contextHints,
    goals,
    plannerBlocks
  };
}

export async function loadGoalPlanWorkflowContext(
  userID: string,
  payload: GoalPlanGenerationPayload
): Promise<GoalPlanWorkflowContext> {
  if (payload.goal) {
    return {
      goal: {
        id: payload.goalID ?? null,
        title: payload.goal.title,
        description: payload.goal.description
      }
    };
  }

  if (payload.goalID) {
    const snapshot = await userScopedCollection(userID, "goals").doc(payload.goalID).get();
    const data = normalizeFirestoreValue(snapshot.data() ?? {}) as Record<string, unknown>;

    return {
      goal: {
        id: snapshot.exists ? snapshot.id : payload.goalID,
        title: String(data.title ?? "Untitled goal"),
        description: String(data.detail ?? data.description ?? "")
      }
    };
  }

  return {
    goal: {
      id: null,
      title: "Untitled goal",
      description: ""
    }
  };
}

async function loadCollectionPreview(
  userID: string,
  collection: string,
  limit: number
): Promise<FirestoreContextDocument[]> {
  const snapshot = await userScopedCollection(userID, collection).limit(limit).get();
  return snapshot.docs.map((document) => ({
    id: document.id,
    data: normalizeFirestoreValue(document.data())
  }));
}
