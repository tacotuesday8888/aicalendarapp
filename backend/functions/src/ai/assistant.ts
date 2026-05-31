import { HttpsError } from "firebase-functions/v2/https";

import {
  assistantDraftCommitSchema,
  assistantRequestSchema,
  goalPlanRequestSchema,
  type AssistantDraftCommitRequest
} from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { normalizeFirestoreValue, serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import { aiFunctionOptions } from "../shared/functionOptions.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";
import { logLegacyAIEndpointUse } from "../shared/legacyInstrumentation.js";
import { runAIWorkflow } from "./router.js";
import { authorizeAndReserveAIUsage, logAIUsage } from "./usage.js";

type AssistantDraftRecord = {
  id: string;
  kind: "goalPlan" | "plannerAdjustment" | "sessionEvaluation" | "checkInSummary";
  title: string;
  detail: string;
};

export const assistantRespond = onAuthenticatedJsonRequest(assistantRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("assistantRespond", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await authorizeAndReserveAIUsage(userID, "assistant_chat");

  try {
    const response = await runAIWorkflow(userID, {
      workflow: "assistant_chat",
      payload: {
        message: data.message,
        timezone: legacyTimezone(),
        currentScreen: "legacy_assistant_endpoint",
        date: stringValue(recordValue(data.snapshot).date) ?? null,
        contextHints: {
          legacyEndpoint: true,
          nextSuggestedAction: stringValue(recordValue(data.snapshot).nextSuggestedAction) ?? null,
          goalCount: data.goals.length
        }
      }
    });

    const threadSnapshot = await userScopedCollection(userID, "assistantThreads").doc("primary").get();
    const thread = normalizeFirestoreValue(threadSnapshot.data() ?? {
      id: "primary",
      messages: [
        {
          id: `primary-user-${Date.now()}`,
          role: "user",
          content: data.message,
          createdAt: new Date().toISOString()
        },
        {
          id: `primary-assistant-${Date.now()}`,
          role: "assistant",
          content: stringValue(recordValue(response.result).message) ?? "AI response completed.",
          createdAt: new Date().toISOString()
        }
      ],
      pendingDrafts: []
    });

    await logAIUsage(userID, "assistant_chat", "success");
    return { thread };
  } catch (error) {
    await logAIUsage(userID, "assistant_chat", "error", { endpoint: "assistantRespond" }).catch(() => undefined);
    throw error;
  }
}, aiFunctionOptions);

export const generateGoalPlan = onAuthenticatedJsonRequest(goalPlanRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("generateGoalPlan", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await authorizeAndReserveAIUsage(userID, "goal_plan_generation");

  try {
    const goal = recordValue(data.goal);
    const response = await runAIWorkflow(userID, {
      workflow: "goal_plan_generation",
      payload: {
        goalID: stringValue(goal.id),
        goal: {
          title: stringValue(goal.title) ?? "Untitled goal",
          description: stringValue(goal.detail) ?? stringValue(goal.description) ?? ""
        },
        timelineWeeks: data.timelineWeeks,
        startDate: new Date().toISOString(),
        timezone: legacyTimezone()
      }
    });

    const result = recordValue(response.result);
    const milestones = Array.isArray(result.milestones) ? result.milestones.map(recordValue) : [];
    const nextActions = Array.isArray(result.nextActions) ? result.nextActions.map(recordValue) : [];
    const draft = {
      id: response.draftID ?? userScopedCollection(userID, "goalPlans").doc().id,
      goalID: stringValue(goal.id) ?? "",
      summary: stringValue(result.summary) ?? "Review this generated plan before adding it to your planner.",
      suggestedTimelineWeeks: data.timelineWeeks,
      checkpoints: milestones.map((milestone, index) => ({
        id: `${response.draftID ?? "legacy-goal-plan"}-checkpoint-${index + 1}`,
        title: stringValue(milestone.title) ?? `Checkpoint ${index + 1}`,
        dueDate: stringValue(milestone.dueDate) ?? new Date().toISOString()
      })),
      nextActions: nextActions.map((action, index) => ({
        id: `${response.draftID ?? "legacy-goal-plan"}-step-${index + 1}`,
        title: stringValue(action.title) ?? `Next action ${index + 1}`,
        isComplete: false
      })),
      createdAt: new Date().toISOString()
    };

    await logAIUsage(userID, "goal_plan_generation", "success");
    return draft;
  } catch (error) {
    await logAIUsage(userID, "goal_plan_generation", "error", { endpoint: "generateGoalPlan" }).catch(
      () => undefined
    );
    throw error;
  }
}, aiFunctionOptions);

export const commitAssistantDraft = onAuthenticatedJsonRequest(assistantDraftCommitSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);

  await confirmDraftArtifact(userID, data);
  return { success: true };
});

function legacyTimezone(): string {
  return process.env.DEFAULT_TIMEZONE?.trim() || "UTC";
}

function recordValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

async function confirmDraftArtifact(userID: string, request: AssistantDraftCommitRequest) {
  const draftRef = userScopedCollection(userID, "assistantDraftArtifacts").doc(request.action.id);
  const snapshot = await draftRef.get();

  if (!snapshot.exists) {
    throw new HttpsError("not-found", "Draft artifact was not found.");
  }

  await draftRef.set(
    {
      status: "confirmed",
      confirmedAt: serverTimestamp()
    },
    { merge: true }
  );

  await applyDraftAction(userID, request);
  await updateAssistantThreadAfterCommit(userID, request);
}

async function applyDraftAction(userID: string, request: AssistantDraftCommitRequest) {
  switch (request.action.kind) {
    case "goalPlan": {
      const draftRef = userScopedCollection(userID, "goalPlans").doc(request.action.id);
      const goalID = await resolveGoalIDForDraftAction(userID, request);
      await draftRef.set(
        {
          id: draftRef.id,
          goalID,
          summary: request.action.detail,
          suggestedTimelineWeeks: 4,
          checkpoints: [],
          nextActions: [
            {
              id: `${draftRef.id}-step-1`,
              title: request.action.title,
              isComplete: false
            }
          ],
          createdAt: serverTimestamp()
        },
        { merge: true }
      );
      break;
    }
    case "plannerAdjustment": {
      const blockRef = userScopedCollection(userID, "plannerBlocks").doc(request.action.id);
      const startDate = new Date();
      const endDate = new Date(startDate.getTime() + 60 * 60 * 1000);
      await blockRef.set(
        {
          id: blockRef.id,
          title: request.action.title,
          detail: request.action.detail,
          startDate: startDate.toISOString(),
          endDate: endDate.toISOString(),
          type: "studySession",
          source: "app",
          linkedGoalID: null,
          linkedAssignmentID: null
        },
        { merge: true }
      );
      break;
    }
    case "sessionEvaluation":
    case "checkInSummary":
      break;
    default:
      throw new HttpsError("invalid-argument", "Unsupported assistant draft action.");
  }
}

async function resolveGoalIDForDraftAction(userID: string, request: AssistantDraftCommitRequest): Promise<string> {
  const snapshot = await userScopedCollection(userID, "goals").get();
  const goals = snapshot.docs.map((document) => ({
    id: document.id,
    title: String(document.get("title") ?? "")
  }));

  const normalizedTitle = normalizeLookupString(String(request.action.title ?? ""));
  const normalizedDetail = normalizeLookupString(String(request.action.detail ?? ""));

  const exactMatch = goals.find((goal) => {
    const normalizedGoalTitle = normalizeLookupString(goal.title);
    return normalizedTitle.includes(normalizedGoalTitle) || normalizedDetail.includes(normalizedGoalTitle);
  });

  if (exactMatch) {
    return exactMatch.id;
  }

  if (goals.length === 1) {
    return goals[0]!.id;
  }

  throw new HttpsError("invalid-argument", "Unable to match this draft to one of your goals.");
}

function normalizeLookupString(value: string): string {
  return value
    .toLowerCase()
    .replace("draft a plan for", "")
    .replace("plan for", "")
    .replaceAll("\"", "")
    .trim();
}

async function updateAssistantThreadAfterCommit(userID: string, request: AssistantDraftCommitRequest) {
  const threadRef = userScopedCollection(userID, "assistantThreads").doc("primary");
  const threadSnapshot = await threadRef.get();
  if (!threadSnapshot.exists) {
    return;
  }

  const threadData = threadSnapshot.data() as {
    id?: string;
    messages?: Array<{ id?: string; role?: string; content?: string; createdAt?: string }>;
    pendingDrafts?: AssistantDraftRecord[];
  };

  const messages = Array.isArray(threadData.messages) ? threadData.messages : [];
  const pendingDrafts = Array.isArray(threadData.pendingDrafts) ? threadData.pendingDrafts : [];
  const updatedMessages = [
    ...messages,
    {
      id: `${threadRef.id}-commit-${Date.now()}`,
      role: "assistant",
      content: `Draft committed: ${request.action.title}`,
      createdAt: new Date().toISOString()
    }
  ];

  await threadRef.set(
    {
      id: threadData.id ?? threadRef.id,
      messages: updatedMessages,
      pendingDrafts: pendingDrafts.filter((draft) => draft.id !== request.action.id),
      updatedAt: serverTimestamp()
    },
    { merge: true }
  );
}
