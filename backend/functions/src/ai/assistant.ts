import { HttpsError } from "firebase-functions/v2/https";

import {
  assistantDraftCommitSchema,
  assistantRequestSchema,
  goalPlanRequestSchema,
  type AssistantDraftCommitRequest,
  type AssistantRequest,
  type GoalPlanRequest
} from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import { aiFunctionOptions } from "../shared/functionOptions.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";
import { logLegacyAIEndpointUse } from "../shared/legacyInstrumentation.js";
import { AI_DISABLED_MESSAGE, createAIProvider, isAIDisabledResponse } from "./provider.js";
import {
  buildAssistantSystemPrompt,
  buildAssistantUserPrompt,
  buildGoalPlanPrompt
} from "./prompts.js";
import { crisisSafetyFeedback } from "./safety.js";
import { authorizeAndReserveAIUsage, logAIUsage } from "./usage.js";

type AssistantDraftRecord = {
  id: string;
  kind: "goalPlan" | "plannerAdjustment" | "sessionEvaluation" | "checkInSummary";
  title: string;
  detail: string;
};

type GoalPlanCompletion = {
  summary: string;
  checkpoints?: Array<{
    title?: string;
    dueDate?: string;
  }>;
  nextActions?: Array<{
    title?: string;
    isComplete?: boolean;
  }>;
};

export const assistantRespond = onAuthenticatedJsonRequest(assistantRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("assistantRespond", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await authorizeAndReserveAIUsage(userID, "assistant_chat");

  const thread = await createAssistantThread(userID, data);
  await logAIUsage(userID, "assistant_chat", "success");
  return { thread };
}, aiFunctionOptions);

export const generateGoalPlan = onAuthenticatedJsonRequest(goalPlanRequestSchema, async ({ authUID, data, request }) => {
  logLegacyAIEndpointUse("generateGoalPlan", authUID, request);
  const userID = requireMatchingUser(authUID, data.userID);
  await authorizeAndReserveAIUsage(userID, "goal_plan_generation");

  const draft = await createGoalPlanDraft(userID, data);
  await logAIUsage(userID, "goal_plan_generation", "success");
  return draft;
}, aiFunctionOptions);

export const commitAssistantDraft = onAuthenticatedJsonRequest(assistantDraftCommitSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);

  await confirmDraftArtifact(userID, data);
  return { success: true };
});

async function createAssistantThread(userID: string, request: AssistantRequest) {
  const safetyFeedback = crisisSafetyFeedback(request.message);
  if (safetyFeedback) {
    return appendAssistantExchange(userID, request.message, safetyFeedback, []);
  }

  const provider = createAIProvider();
  const response = await provider.complete({
    system: buildAssistantSystemPrompt(),
    user: buildAssistantUserPrompt(request)
  });

  const parsed = parseAssistantCompletion(response.text, request);
  const threads = userScopedCollection(userID, "assistantThreads");
  const threadRef = threads.doc("primary");
  const threadSnapshot = await threadRef.get();
  const existingThread = threadSnapshot.data() as
    | {
        messages?: unknown[];
        pendingDrafts?: AssistantDraftRecord[];
      }
    | undefined;
  const existingMessages = Array.isArray(existingThread?.messages) ? existingThread.messages : [];
  const existingPendingDrafts = Array.isArray(existingThread?.pendingDrafts) ? existingThread.pendingDrafts : [];
  const timestamp = Date.now();
  const newDrafts = parsed.draftActions.map((draft, index) => ({
    ...draft,
    id: `${threadRef.id}-draft-${timestamp}-${index + 1}`
  }));
  const pendingDrafts = [...existingPendingDrafts, ...newDrafts];

  const messages = [
    ...existingMessages,
    {
      id: `${threadRef.id}-user-${timestamp}`,
      role: "user",
      content: request.message,
      createdAt: new Date().toISOString()
    },
    {
      id: `${threadRef.id}-assistant-${timestamp}`,
      role: "assistant",
      content: parsed.message,
      createdAt: new Date().toISOString()
    }
  ];

  await Promise.all([
    threadRef.set(
      {
        id: threadRef.id,
        messages,
        pendingDrafts,
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
        createdAt: serverTimestamp()
      })
    )
  ]);

  return {
    id: threadRef.id,
    messages,
    pendingDrafts
  };
}

async function appendAssistantExchange(
  userID: string,
  userMessage: string,
  assistantMessage: string,
  newDrafts: AssistantDraftRecord[]
) {
  const threads = userScopedCollection(userID, "assistantThreads");
  const threadRef = threads.doc("primary");
  const threadSnapshot = await threadRef.get();
  const existingThread = threadSnapshot.data() as
    | {
        messages?: unknown[];
        pendingDrafts?: AssistantDraftRecord[];
      }
    | undefined;
  const existingMessages = Array.isArray(existingThread?.messages) ? existingThread.messages : [];
  const existingPendingDrafts = Array.isArray(existingThread?.pendingDrafts) ? existingThread.pendingDrafts : [];
  const timestamp = Date.now();
  const pendingDrafts = [...existingPendingDrafts, ...newDrafts];
  const messages = [
    ...existingMessages,
    {
      id: `${threadRef.id}-user-${timestamp}`,
      role: "user",
      content: userMessage,
      createdAt: new Date(timestamp).toISOString()
    },
    {
      id: `${threadRef.id}-assistant-${timestamp}`,
      role: "assistant",
      content: assistantMessage,
      createdAt: new Date(timestamp).toISOString()
    }
  ];

  await threadRef.set(
    {
      id: threadRef.id,
      messages,
      pendingDrafts,
      createdAt: threadSnapshot.exists ? threadSnapshot.get("createdAt") ?? serverTimestamp() : serverTimestamp(),
      updatedAt: serverTimestamp()
    },
    { merge: true }
  );

  return {
    id: threadRef.id,
    messages,
    pendingDrafts
  };
}

async function createGoalPlanDraft(userID: string, request: GoalPlanRequest) {
  const provider = createAIProvider();
  const response = await provider.complete({
    system: buildAssistantSystemPrompt(),
    user: buildGoalPlanPrompt(request)
  });

  const goalPlans = userScopedCollection(userID, "goalPlans");
  const draftRef = goalPlans.doc();
  const parsed = parseGoalPlanCompletion(response.text, request, draftRef.id);

  const draft = {
    id: draftRef.id,
    goalID: String(request.goal.id ?? ""),
    summary: parsed.summary,
    suggestedTimelineWeeks: request.timelineWeeks,
    checkpoints: parsed.checkpoints,
    nextActions: parsed.nextActions,
    createdAt: new Date().toISOString()
  };

  await Promise.all([
    draftRef.set({
      ...draft,
      createdAt: serverTimestamp()
    })
  ]);

  return draft;
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

function parseAssistantCompletion(rawText: string, request: AssistantRequest) {
  if (isAIDisabledResponse(rawText)) {
    return {
      message: `${AI_DISABLED_MESSAGE} You can still manage goals, sessions, check-ins, and imports while AI is deferred.`,
      draftActions: []
    };
  }

  const fallbackMessage =
    rawText.trim() ||
    `Keep the next move small and visible. Prioritize "${request.snapshot.nextSuggestedAction}" and protect one focused block today.`;

  const fallbackDrafts = buildFallbackDrafts(request);
  const parsed = parseJSONObject(rawText) as
    | {
        message?: string;
        draftActions?: Array<{
          kind?: string;
          title?: string;
          detail?: string;
        }>;
      }
    | undefined;

  const message = parsed?.message?.trim() || fallbackMessage;
  const draftActions = (parsed?.draftActions ?? [])
    .map((draft) => {
      const kind = normalizeDraftKind(draft.kind);
      const title = draft.title?.trim();
      const detail = draft.detail?.trim();

      if (!kind || !title || !detail) {
        return null;
      }

      return { kind, title, detail };
    })
    .filter((draft): draft is Omit<AssistantDraftRecord, "id"> => draft !== null);

  return {
    message,
    draftActions: draftActions.length ? draftActions : fallbackDrafts
  };
}

function parseGoalPlanCompletion(rawText: string, request: GoalPlanRequest, draftID: string) {
  if (isAIDisabledResponse(rawText)) {
    return {
      summary: `${AI_DISABLED_MESSAGE} Goal plans will appear here after the provider decision is made.`,
      checkpoints: [],
      nextActions: []
    };
  }

  const parsed = parseJSONObject(rawText) as GoalPlanCompletion | undefined;
  const checkpointDate = new Date();
  checkpointDate.setDate(checkpointDate.getDate() + request.timelineWeeks * 7);

  const fallback = {
    summary: rawText.trim() || "A realistic plan will work best when you protect a few specific milestones each week.",
    checkpoints: [
      {
        id: `${draftID}-checkpoint`,
        title: "First review checkpoint",
        dueDate: checkpointDate.toISOString()
      }
    ],
    nextActions: [
      {
        id: `${draftID}-step`,
        title: "Review and confirm this AI-generated plan",
        isComplete: false
      }
    ]
  };

  if (!parsed?.summary?.trim()) {
    return fallback;
  }

  const checkpoints = (parsed.checkpoints ?? [])
    .map((checkpoint, index) => {
      const title = checkpoint.title?.trim();
      const dueDate = checkpoint.dueDate && !Number.isNaN(Date.parse(checkpoint.dueDate))
        ? new Date(checkpoint.dueDate).toISOString()
        : null;

      if (!title || !dueDate) {
        return null;
      }

      return {
        id: `${draftID}-checkpoint-${index + 1}`,
        title,
        dueDate
      };
    })
    .filter((checkpoint): checkpoint is { id: string; title: string; dueDate: string } => checkpoint !== null);

  const nextActions = (parsed.nextActions ?? [])
    .map((action, index) => {
      const title = action.title?.trim();
      if (!title) {
        return null;
      }

      return {
        id: `${draftID}-step-${index + 1}`,
        title,
        isComplete: false
      };
    })
    .filter((action): action is { id: string; title: string; isComplete: boolean } => action !== null);

  return {
    summary: parsed.summary.trim(),
    checkpoints: checkpoints.length ? checkpoints : fallback.checkpoints,
    nextActions: nextActions.length ? nextActions : fallback.nextActions
  };
}

function buildFallbackDrafts(request: AssistantRequest): Array<Omit<AssistantDraftRecord, "id">> {
  const drafts: Array<Omit<AssistantDraftRecord, "id">> = [];
  const normalized = request.message.toLowerCase();

  if (normalized.includes("goal") || normalized.includes("plan")) {
    const goal = request.goals[0];
    drafts.push({
      kind: "goalPlan",
      title: goal ? `Draft a plan for ${goal.title}` : "Draft a plan for your top goal",
      detail: goal
        ? `Break ${goal.title} into weekly checkpoints and immediate next steps.`
        : "Turn your current priority into weekly checkpoints and immediate next steps."
    });
  }

  if (normalized.includes("schedule") || normalized.includes("calendar") || normalized.includes("time")) {
    drafts.push({
      kind: "plannerAdjustment",
      title: "Protect a focused block",
      detail: `Schedule focused time around "${request.snapshot.nextSuggestedAction}".`
    });
  }

  if (normalized.includes("session") || normalized.includes("focus")) {
    drafts.push({
      kind: "sessionEvaluation",
      title: "Evaluate the next study session",
      detail: "After your next session, capture what worked and what needs adjustment."
    });
  }

  if (normalized.includes("stress") || normalized.includes("check") || normalized.includes("reflect")) {
    drafts.push({
      kind: "checkInSummary",
      title: "Capture a quick reflection",
      detail: "Use the next check-in to log what feels heavy and what can be simplified."
    });
  }

  if (!drafts.length) {
    drafts.push({
      kind: "plannerAdjustment",
      title: "Tighten the next step",
      detail: `Use "${request.snapshot.nextSuggestedAction}" as the next visible action in your schedule.`
    });
  }

  return drafts.slice(0, 3);
}

function normalizeDraftKind(kind: string | undefined): AssistantDraftRecord["kind"] | null {
  switch (kind) {
    case "goalPlan":
    case "plannerAdjustment":
    case "sessionEvaluation":
    case "checkInSummary":
      return kind;
    default:
      return null;
  }
}

function parseJSONObject(rawText: string): unknown {
  const trimmed = rawText.trim();
  if (!trimmed) {
    return undefined;
  }

  const candidates = [trimmed, trimmed.replace(/^```json\s*/i, "").replace(/```$/i, "").trim()];

  const firstBrace = trimmed.indexOf("{");
  const lastBrace = trimmed.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    candidates.push(trimmed.slice(firstBrace, lastBrace + 1));
  }

  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate);
    } catch {
      continue;
    }
  }

  return undefined;
}
