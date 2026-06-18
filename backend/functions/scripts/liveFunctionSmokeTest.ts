import assert from "node:assert/strict";

type JsonObject = Record<string, unknown>;
type SmokeRequest = {
  name: string;
  path: string;
  body: JsonObject;
  assertResponse: (responseJSON: unknown) => void;
};
type LiveSmokeState = {
  premiumAIIncluded: boolean;
  assistantChatCompleted: boolean;
  baselineAIUsageIDs?: Set<string>;
  goalPlanDraftID?: string;
  syllabusImportDraftID?: string;
};

const PREMIUM_AI_WORKFLOWS = ["assistant_chat", "goal_plan_generation", "syllabus_import"] as const;

async function runLiveFunctionSmokeTest() {
  const dryRun = process.env.LIVE_SMOKE_DRY_RUN === "true";
  const functionsBaseURL = requireEnv("FUNCTIONS_BASE_URL").replace(/\/+$/, "");
  const idToken = dryRun ? process.env.FIREBASE_ID_TOKEN?.trim() ?? "" : requireEnv("FIREBASE_ID_TOKEN");
  const userID = dryRun ? process.env.SMOKE_USER_ID?.trim() || "dry-run-user" : requireEnv("SMOKE_USER_ID");
  const appCheckToken = process.env.FIREBASE_APP_CHECK_TOKEN?.trim();
  const headers: Record<string, string> = {
    "Accept": "application/json",
    "Content-Type": "application/json"
  };

  if (idToken) {
    headers.Authorization = `Bearer ${idToken}`;
  }

  if (appCheckToken) {
    headers["X-Firebase-AppCheck"] = appCheckToken;
  } else if (!dryRun) {
    console.warn("FIREBASE_APP_CHECK_TOKEN is not set; this should only pass while APP_CHECK_MODE=monitor.");
  }

  const requests = liveSmokeRequests(userID);

  if (dryRun) {
    console.log(
      JSON.stringify(
        {
          dryRun: true,
          hasAuthorization: Boolean(headers.Authorization),
          hasAppCheck: Boolean(headers["X-Firebase-AppCheck"]),
          requests: requests.map((request) => ({
            name: request.name,
            method: "POST",
            url: urlFor(functionsBaseURL, request.path).toString(),
            bodyKeys: Object.keys(request.body)
          }))
        },
        null,
        2
      )
    );
    return;
  }

  for (const request of requests) {
    const url = urlFor(functionsBaseURL, request.path);
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(request.body)
    });
    const responseText = await response.text();
    const responseJSON = parseJSON(responseText);

    if (!response.ok) {
      throw new Error(`${request.name} failed with HTTP ${response.status}: ${responseText}`);
    }

    request.assertResponse(responseJSON);
    console.log(`${request.name} passed against ${url.toString()}.`);
  }

  console.log(`Live function smoke matrix passed for ${requests.length} request(s).`);
}

function liveSmokeRequests(userID: string): SmokeRequest[] {
  const timezone = process.env.SMOKE_TIMEZONE?.trim() || "America/New_York";
  const currentDate = process.env.SMOKE_CURRENT_DATE?.trim() || new Date().toISOString();
  const state: LiveSmokeState = {
    premiumAIIncluded: process.env.LIVE_SMOKE_INCLUDE_PREMIUM_AI === "true",
    assistantChatCompleted: false
  };
  const requests: SmokeRequest[] = [
    {
      name: "ai/run vibe_feedback",
      path: "ai/run",
      body: {
        workflow: "vibe_feedback",
        payload: {
          reflectionText: process.env.SMOKE_REFLECTION_TEXT?.trim() || "I feel behind today, but I can start with one small task.",
          timezone,
          recentContext: {
            userID
          }
        }
      },
      assertResponse: assertVibeFeedbackResponse
    },
    {
      name: "syncRevenueCatSubscription",
      path: "syncRevenueCatSubscription",
      body: {
        userID
      },
      assertResponse: (responseJSON) => assertSubscriptionSyncResponse(responseJSON, state.premiumAIIncluded)
    }
  ];

  if (state.premiumAIIncluded) {
    requests.push({
      name: "exportUserData premium AI baseline",
      path: "exportUserData",
      body: {
        userID
      },
      assertResponse: (responseJSON) => {
        const collections = assertExportUserDataResponse(responseJSON, userID);
        state.baselineAIUsageIDs = collectionIDSet(collections, "aiUsage");
      }
    });

    requests.push(
      {
        name: "ai/run assistant_chat",
        path: "ai/run",
        body: {
          workflow: "assistant_chat",
          payload: {
            message:
              process.env.SMOKE_ASSISTANT_MESSAGE?.trim() ||
              "Help me plan one focused study block for calculus today.",
            timezone,
            currentScreen: "assistant",
            date: currentDate,
            contextHints: {
              userID,
              smokeTest: true,
              upcomingDeadline: "calculus quiz Friday"
            }
          }
        },
        assertResponse: (responseJSON) => {
          assertAssistantChatResponse(responseJSON);
          state.assistantChatCompleted = true;
        }
      },
      {
        name: "ai/run goal_plan_generation",
        path: "ai/run",
        body: {
          workflow: "goal_plan_generation",
          payload: {
            goalID: "live-smoke-goal",
            goal: {
              title: process.env.SMOKE_GOAL_TITLE?.trim() || "Improve calculus exam readiness",
              description:
                process.env.SMOKE_GOAL_DESCRIPTION?.trim() ||
                "Prepare for a calculus exam by reviewing notes, completing practice problems, and checking weak topics."
            },
            timelineWeeks: 4,
            startDate: currentDate,
            timezone
          }
        },
        assertResponse: (responseJSON) => {
          const response = assertGoalPlanGenerationResponse(responseJSON);
          state.goalPlanDraftID = String(response.draftID);
        }
      },
      {
        name: "ai/run syllabus_import",
        path: "ai/run",
        body: {
          workflow: "syllabus_import",
          payload: {
            extractedText:
              process.env.SMOKE_SYLLABUS_TEXT?.trim() ||
              [
                "CS 101 Syllabus",
                "Instructor: Dr. Rivera",
                "Homework 1 due 2026-09-12",
                "Midterm exam due 2026-10-18",
                "Final project due 2026-12-02"
              ].join("\n"),
            currentDate,
            timezone,
            sourceName: "live-smoke-syllabus.txt",
            uploadedFilePath: null
          }
        },
        assertResponse: (responseJSON) => {
          const response = assertSyllabusImportResponse(responseJSON);
          state.syllabusImportDraftID = String(response.draftID);
        }
      }
    );
  }

  requests.push({
    name: "exportUserData",
    path: "exportUserData",
    body: {
      userID
    },
    assertResponse: (responseJSON) => assertExportUserDataResponse(responseJSON, userID, state)
  });

  if (process.env.LIVE_SMOKE_INCLUDE_DELETE_ACCOUNT === "true") {
    const confirmation = process.env.LIVE_SMOKE_CONFIRM_DELETE_ACCOUNT?.trim();
    assert.equal(
      confirmation,
      `DELETE ${userID}`,
      "LIVE_SMOKE_CONFIRM_DELETE_ACCOUNT must equal `DELETE ${SMOKE_USER_ID}` before deleteUserAccount is included."
    );
    requests.push({
      name: "deleteUserAccount",
      path: "deleteUserAccount",
      body: {
        userID
      },
      assertResponse: (responseJSON) => assertDeleteUserAccountResponse(responseJSON, userID)
    });
  }

  return requests;
}

function assertVibeFeedbackResponse(responseJSON: unknown) {
  const response = assertAIWorkflowResponse(responseJSON, "vibe_feedback");
  assertNonEmptyString(response.result.feedback, "vibe_feedback result.feedback");
}

function assertAssistantChatResponse(responseJSON: unknown): { draftID: unknown; result: JsonObject } {
  const response = assertAIWorkflowResponse(responseJSON, "assistant_chat");
  assertNonEmptyString(response.result.message, "assistant_chat result.message");

  const draftActions = assertArrayProperty(response.result, "draftActions", "assistant_chat result.draftActions");
  draftActions.forEach((value, index) => {
    assert.ok(isJsonObject(value), `Expected assistant_chat draftActions[${index}] to be an object.`);
    assertNonEmptyString(value.type, `assistant_chat draftActions[${index}].type`);
    assertNonEmptyString(value.title, `assistant_chat draftActions[${index}].title`);
    assertNonEmptyString(value.reason, `assistant_chat draftActions[${index}].reason`);
    assert.ok(
      value.dueAt === null || value.dueAt === undefined || typeof value.dueAt === "string",
      `Expected assistant_chat draftActions[${index}].dueAt to be a string, null, or omitted.`
    );
  });

  assertOptionalDraftID(response.draftID, "assistant_chat draftID");
  return response;
}

function assertGoalPlanGenerationResponse(responseJSON: unknown): { draftID: unknown; result: JsonObject } {
  const response = assertAIWorkflowResponse(responseJSON, "goal_plan_generation");
  assertNonEmptyString(response.result.summary, "goal_plan_generation result.summary");

  const milestones = assertArrayProperty(response.result, "milestones", "goal_plan_generation result.milestones");
  assert.ok(milestones.length > 0, "Expected goal_plan_generation to return at least one milestone.");
  milestones.forEach((value, index) => {
    assert.ok(isJsonObject(value), `Expected goal_plan_generation milestones[${index}] to be an object.`);
    assertNonEmptyString(value.title, `goal_plan_generation milestones[${index}].title`);
    assertNonEmptyString(value.dueDate, `goal_plan_generation milestones[${index}].dueDate`);
    assertNonEmptyString(value.description, `goal_plan_generation milestones[${index}].description`);
  });

  const nextActions = assertArrayProperty(response.result, "nextActions", "goal_plan_generation result.nextActions");
  assert.ok(nextActions.length >= 3, "Expected goal_plan_generation to return at least three next actions.");
  nextActions.forEach((value, index) => {
    assert.ok(isJsonObject(value), `Expected goal_plan_generation nextActions[${index}] to be an object.`);
    assertNonEmptyString(value.title, `goal_plan_generation nextActions[${index}].title`);
    assert.equal(typeof value.estimatedMinutes, "number", `Expected goal_plan_generation nextActions[${index}].estimatedMinutes number.`);
    assert.ok(
      value.priority === "low" || value.priority === "medium" || value.priority === "high",
      `Expected goal_plan_generation nextActions[${index}].priority to be low, medium, or high.`
    );
  });

  assertNonEmptyString(response.draftID, "goal_plan_generation draftID");
  return response;
}

function assertSyllabusImportResponse(responseJSON: unknown): { draftID: unknown; result: JsonObject } {
  const response = assertAIWorkflowResponse(responseJSON, "syllabus_import");

  const courses = assertArrayProperty(response.result, "courses", "syllabus_import result.courses");
  assert.ok(courses.length > 0, "Expected syllabus_import to return at least one course.");
  let assignmentCount = 0;
  courses.forEach((value, index) => {
    assert.ok(isJsonObject(value), `Expected syllabus_import courses[${index}] to be an object.`);
    assertNonEmptyString(value.name, `syllabus_import courses[${index}].name`);
    assert.ok(
      value.instructor === null || value.instructor === undefined || typeof value.instructor === "string",
      `Expected syllabus_import courses[${index}].instructor to be a string, null, or omitted.`
    );
    assignmentCount += assertArrayProperty(value, "assignments", `syllabus_import courses[${index}].assignments`).length;
  });
  assert.ok(assignmentCount > 0, "Expected syllabus_import to return at least one assignment.");

  assertArrayProperty(response.result, "warnings", "syllabus_import result.warnings");
  assertNonEmptyString(response.draftID, "syllabus_import draftID");
  return response;
}

function assertSubscriptionSyncResponse(responseJSON: unknown, requireActiveEntitlement = false) {
  assert.ok(isJsonObject(responseJSON), "Expected subscription sync to return a JSON object.");
  assert.equal(responseJSON.success, true, "Expected subscription sync success=true.");
  assert.ok(isJsonObject(responseJSON.subscription), "Expected subscription sync to return a subscription object.");

  const subscription = responseJSON.subscription;
  assert.ok(
    subscription.entitlement === "active" || subscription.entitlement === "inactive",
    "Expected subscription entitlement to be active or inactive."
  );
  assert.ok(
    subscription.activePlan === "monthly" || subscription.activePlan === "annual" || subscription.activePlan === "none",
    "Expected subscription activePlan to be monthly, annual, or none."
  );
  assert.equal(typeof subscription.trialEligible, "boolean", "Expected subscription trialEligible boolean.");
  assert.equal(typeof subscription.lastSyncedAt, "string", "Expected subscription lastSyncedAt string.");

  if (requireActiveEntitlement) {
    assert.equal(
      subscription.entitlement,
      "active",
      "LIVE_SMOKE_INCLUDE_PREMIUM_AI requires an active subscription snapshot. Add the disposable user to BETA_PRO_USER_IDS or give it a test RevenueCat entitlement."
    );
    assert.equal(subscription.trialEligible, false, "Expected premium smoke user to be trialEligible=false.");
  }
}

function assertExportUserDataResponse(responseJSON: unknown, userID: string, state?: LiveSmokeState): JsonObject {
  assert.ok(isJsonObject(responseJSON), "Expected exportUserData to return a JSON object.");
  assert.equal(responseJSON.userID, userID, "Expected exportUserData to return the requested userID.");
  assert.equal(typeof responseJSON.requestedAt, "string", "Expected exportUserData requestedAt string.");
  assert.ok(isJsonObject(responseJSON.profile), "Expected exportUserData profile object.");
  const collections = assertExportCollections(responseJSON);

  if (state?.premiumAIIncluded) {
    assert.ok(state.baselineAIUsageIDs, "Expected premium AI baseline export to run before final export verification.");
    assert.ok(state.assistantChatCompleted, "Expected assistant_chat smoke request to complete before export verification.");
    assertCollectionContainsID(collections, "assistantThreads", "primary");

    assertNonEmptyString(state.goalPlanDraftID, "captured goal plan draft ID");
    assertCollectionContainsID(collections, "goalPlans", state.goalPlanDraftID);
    assertCollectionContainsID(collections, "aiDrafts", state.goalPlanDraftID);

    assertNonEmptyString(state.syllabusImportDraftID, "captured syllabus import draft ID");
    assertCollectionContainsID(collections, "imports", state.syllabusImportDraftID);
    assertPremiumAIUsageRecords(collections, state.baselineAIUsageIDs);
  }

  return collections;
}

function assertDeleteUserAccountResponse(responseJSON: unknown, userID: string) {
  assert.ok(isJsonObject(responseJSON), "Expected deleteUserAccount to return a JSON object.");
  assert.equal(responseJSON.success, true, "Expected deleteUserAccount success=true.");
  assert.equal(responseJSON.userID, userID, "Expected deleteUserAccount to return the deleted userID.");
  assert.ok(isJsonObject(responseJSON.deletedCollections), "Expected deleteUserAccount deletedCollections object.");
}

function assertAIWorkflowResponse(responseJSON: unknown, workflow: string): { draftID: unknown; result: JsonObject } {
  assert.ok(isJsonObject(responseJSON), "Expected ai/run to return a JSON object.");
  assert.equal(responseJSON.workflow, workflow, `Expected ai/run to return the ${workflow} workflow.`);
  assert.notEqual(responseJSON.degraded, true, `Expected ${workflow} live smoke to use the configured live AI provider without degraded fallback.`);
  assert.ok(isJsonObject(responseJSON.result), "Expected ai/run to return a result object.");
  assert.notEqual(responseJSON.result.degraded, true, `Expected ${workflow} result to avoid degraded fallback output.`);
  return {
    draftID: responseJSON.draftID,
    result: responseJSON.result
  };
}

function assertExportCollections(responseJSON: JsonObject): JsonObject {
  assert.ok(isJsonObject(responseJSON.collections), "Expected exportUserData collections object.");
  return responseJSON.collections;
}

function assertCollectionContainsID(collections: JsonObject, collectionName: string, id: string) {
  const records = assertArrayProperty(collections, collectionName, `exportUserData collections.${collectionName}`);
  const hasRecord = records.some((record) => isJsonObject(record) && record.id === id);
  assert.ok(hasRecord, `Expected exportUserData collections.${collectionName} to contain ${id}.`);
}

function assertPremiumAIUsageRecords(collections: JsonObject, baselineAIUsageIDs: Set<string>) {
  const expectedProvider = process.env.SMOKE_EXPECTED_AI_PROVIDER?.trim() || "vertex";
  const expectedModel = process.env.SMOKE_EXPECTED_AI_MODEL?.trim() || "gemini-3.1-flash-lite";
  const newUsageRecords = assertArrayProperty(collections, "aiUsage", "exportUserData collections.aiUsage")
    .filter((record): record is JsonObject =>
      isJsonObject(record) &&
      typeof record.id === "string" &&
      !baselineAIUsageIDs.has(record.id)
    );

  for (const workflow of PREMIUM_AI_WORKFLOWS) {
    const matchingRecord = newUsageRecords.find((record) =>
      record.workflow === workflow &&
      record.status === "success" &&
      record.provider === expectedProvider &&
      record.model === expectedModel
    );

    assert.ok(
      matchingRecord,
      `Expected a new aiUsage success record for ${workflow} with provider=${expectedProvider} and model=${expectedModel}.`
    );
  }
}

function collectionIDSet(collections: JsonObject, collectionName: string): Set<string> {
  return new Set(
    assertArrayProperty(collections, collectionName, `exportUserData collections.${collectionName}`)
      .filter((record): record is JsonObject & { id: string } => isJsonObject(record) && typeof record.id === "string")
      .map((record) => record.id)
  );
}

function assertArrayProperty(record: JsonObject, propertyName: string, label: string): unknown[] {
  const value = record[propertyName];
  assert.ok(Array.isArray(value), `Expected ${label} array.`);
  return value;
}

function assertNonEmptyString(value: unknown, label: string): asserts value is string {
  if (typeof value !== "string") {
    assert.fail(`Expected ${label} string.`);
  }
  assert.ok(value.length > 0, `Expected non-empty ${label}.`);
}

function assertOptionalDraftID(value: unknown, label: string) {
  assert.ok(value === null || value === undefined || typeof value === "string", `Expected ${label} string, null, or omitted.`);
  if (typeof value === "string") {
    assert.ok(value.length > 0, `Expected non-empty ${label} when present.`);
  }
}

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function parseJSON(rawValue: string): unknown {
  try {
    return JSON.parse(rawValue);
  } catch {
    return rawValue;
  }
}

function isJsonObject(value: unknown): value is JsonObject {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function urlFor(functionsBaseURL: string, path: string): URL {
  return new URL(path, `${functionsBaseURL}/`);
}

runLiveFunctionSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
