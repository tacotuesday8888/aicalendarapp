import assert from "node:assert/strict";

import {
  assertAIProviderRuntimeConfiguration,
  getAIModelName,
  getAIProviderMode,
  getAIVertexLocation,
  isManagedFirebaseRuntime,
  isAIStubFallbackEnabled
} from "../src/ai/config.js";
import {
  assistantChatFlow,
  goalPlanGenerationFlow,
  syllabusImportFlow,
  vibeFeedbackFlow
} from "../src/ai/workflows.js";
import {
  assistantChatResultSchema,
  goalPlanGenerationResultSchema,
  syllabusImportResultSchema,
  vibeFeedbackResultSchema
} from "../src/ai/schemas.js";
import {
  ASSISTANT_CHAT_SYSTEM_PROMPT,
  BASE_SYSTEM_PROMPT,
  GOAL_PLAN_GENERATION_SYSTEM_PROMPT,
  SCHEDULE_PLANNER_GENERATION_SYSTEM_PROMPT,
  STUDY_SESSION_SUPPORT_SYSTEM_PROMPT,
  SYLLABUS_IMPORT_SYSTEM_PROMPT,
  VIBE_FEEDBACK_SYSTEM_PROMPT
} from "../src/ai/prompts/index.js";
import {
  DEFAULT_FREE_DAILY_LIMIT,
  DEFAULT_PREMIUM_DAILY_LIMIT,
  dailyLimitForWorkflow,
  entitlementWithBetaProAccess,
  isBetaProUserID,
  nextWorkflowCountsForReservation
} from "../src/ai/usagePolicy.js";
import { needsCrisisSafetyResponse, reviewVibeFeedbackForCrisis } from "../src/ai/safety.js";
import {
  buildRevenueCatWebhookSnapshotPlan,
  configuredRevenueCatEntitlementIDs,
  deriveBetaProSnapshot,
  deriveSnapshotFromEvent,
  deriveSnapshotFromSubscriberResponse,
  requiresFreshSnapshotForTransferDestination,
  subscriptionSyncResponse
} from "../src/billing/revenuecat.js";
import {
  firebaseMessagingErrorCode,
  isInvalidPushTokenError
} from "../src/notifications/dispatch.js";

process.env.AI_PROVIDER = "stub";

async function runSmokeTest() {
  assertAIConfigDefaults();
  assertPromptContracts();
  assertUsagePolicy();
  assertSubscriptionSyncContract();
  assertNotificationDispatchContract();

  const assistantInput = {
    userID: "smoke-test-user",
    payload: {
      message: "Help me plan my chemistry deadline.",
      timezone: "America/New_York",
      currentScreen: "Today",
      date: "2026-04-26",
      contextHints: {}
    },
    context: {
      timezone: "America/New_York",
      currentScreen: "Today",
      date: "2026-04-26",
      contextHints: {},
      goals: [{ id: "goal-1", data: { title: "Chemistry project" } }],
      plannerBlocks: [{ id: "block-1", data: { title: "Study block" } }]
    }
  };

  const assistantResult = await assistantChatFlow(assistantInput);
  assistantChatResultSchema.parse(assistantResult);
  assistantChatResultSchema.parse({ ...assistantResult, degraded: true });
  assert.equal(assistantResult.draftActions.length, 1);

  const identityResult = await assistantChatFlow({
    ...assistantInput,
    payload: {
      ...assistantInput.payload,
      message: "What model are you?"
    }
  });
  assert.equal(
    identityResult.message,
    "I’m your in-app productivity assistant, here to help you plan, study, and stay organized."
  );
  assert.deepEqual(identityResult.draftActions, []);

  const assistantSafetyResult = await assistantChatFlow({
    ...assistantInput,
    payload: {
      ...assistantInput.payload,
      message: "I want to die."
    }
  });
  assert.ok(assistantSafetyResult.message.includes("988"));
  assert.deepEqual(assistantSafetyResult.draftActions, []);

  const streamedAssistant = assistantChatFlow.stream(assistantInput);
  let chunkCount = 0;
  for await (const chunk of streamedAssistant.stream) {
    assert.equal(typeof chunk, "string");
    chunkCount += 1;
  }
  assert.ok(chunkCount > 0, "assistant_chat should stream at least one text chunk");
  assistantChatResultSchema.parse(await streamedAssistant.output);

  const goalPlanResult = await goalPlanGenerationFlow({
    userID: "smoke-test-user",
    payload: {
      goalID: null,
      goal: {
        title: "Finish history paper",
        description: "Write and revise a final paper."
      },
      timelineWeeks: 4,
      startDate: "2026-04-26T00:00:00.000Z",
      timezone: "America/New_York"
    },
    context: {
      goal: {
        id: null,
        title: "Finish history paper",
        description: "Write and revise a final paper."
      }
    }
  });
  goalPlanGenerationResultSchema.parse(goalPlanResult);

  const vibeResult = await vibeFeedbackFlow({
    userID: "smoke-test-user",
    payload: {
      reflectionText: "I feel behind but I can start small.",
      timezone: "America/New_York",
      recentContext: {}
    }
  });
  vibeFeedbackResultSchema.parse(vibeResult);
  assert.equal(vibeResult.needs_escalation, false);

  const escalationResult = await vibeFeedbackFlow({
    userID: "smoke-test-user",
    payload: {
      reflectionText: "I want to kill myself.",
      timezone: "America/New_York",
      recentContext: {}
    }
  });
  vibeFeedbackResultSchema.parse(escalationResult);
  assert.equal(escalationResult.needs_escalation, true);

  assert.equal(needsCrisisSafetyResponse("quiero morir"), true);
  assert.equal(needsCrisisSafetyResponse("je veux mourir"), true);
  assert.equal(needsCrisisSafetyResponse("我不想活了"), true);
  assert.deepEqual(
    reviewVibeFeedbackForCrisis({
      feedback: "If you feel suicidal, reach out right now.",
      needs_escalation: false
    }),
    {
      feedback:
        "This sounds urgent. If you might hurt yourself or someone else, call local emergency services now. " +
        "In the U.S. or Canada, call or text 988 for crisis support. If you can, move near another person " +
        "and put distance between yourself and anything you could use to get hurt.",
      needs_escalation: true
    }
  );

  const syllabusResult = await syllabusImportFlow({
    userID: "smoke-test-user",
    payload: {
      extractedText: "Biology 101\nMidterm exam: October 12",
      currentDate: "2026-04-26",
      timezone: "America/New_York"
    }
  });
  syllabusImportResultSchema.parse(syllabusResult);
  assert.equal(syllabusResult.courses[0]?.assignments[0]?.dueDate, null);

  console.log("AI smoke test passed.");
}

function assertAIConfigDefaults() {
  const previousProvider = process.env.AI_PROVIDER;
  const previousModel = process.env.AI_MODEL;
  const previousLocation = process.env.AI_VERTEX_LOCATION;
  const previousCloudLocation = process.env.GCLOUD_LOCATION;
  const previousStubFallback = process.env.AI_ENABLE_STUB_FALLBACK;
  const previousKService = process.env.K_SERVICE;
  const previousFunctionTarget = process.env.FUNCTION_TARGET;
  const previousFunctionSignatureType = process.env.FUNCTION_SIGNATURE_TYPE;
  const previousFunctionsEmulator = process.env.FUNCTIONS_EMULATOR;
  const previousCI = process.env.CI;

  try {
    delete process.env.AI_PROVIDER;
    delete process.env.AI_MODEL;
    delete process.env.AI_VERTEX_LOCATION;
    delete process.env.GCLOUD_LOCATION;
    delete process.env.AI_ENABLE_STUB_FALLBACK;
    delete process.env.K_SERVICE;
    delete process.env.FUNCTION_TARGET;
    delete process.env.FUNCTION_SIGNATURE_TYPE;
    delete process.env.FUNCTIONS_EMULATOR;
    delete process.env.CI;

    assert.equal(getAIProviderMode(), "stub");
    assert.equal(getAIModelName(), "gemini-3.1-flash-lite");
    assert.equal(getAIVertexLocation(), "global");
    assert.equal(isAIStubFallbackEnabled(), false);

    process.env.K_SERVICE = "ai";
    assert.throws(
      () => getAIProviderMode(),
      /AI_PROVIDER is required in managed Firebase runtimes/
    );
    process.env.FUNCTIONS_EMULATOR = "true";
    assert.equal(getAIProviderMode(), "stub");
    delete process.env.K_SERVICE;
    delete process.env.FUNCTIONS_EMULATOR;

    process.env.AI_PROVIDER = "not-a-provider";
    assert.throws(
      () => getAIProviderMode(),
      /Unsupported AI_PROVIDER/
    );

    process.env.AI_PROVIDER = "vertex";
    process.env.AI_MODEL = "custom-model";
    process.env.AI_VERTEX_LOCATION = "us";
    process.env.AI_ENABLE_STUB_FALLBACK = "true";

    assert.equal(getAIProviderMode(), "vertex");
    assert.equal(getAIModelName(), "custom-model");
    assert.equal(getAIVertexLocation(), "us");
    assert.equal(isAIStubFallbackEnabled(), true);
    assert.equal(isManagedFirebaseRuntime(), false);
    assert.doesNotThrow(() => assertAIProviderRuntimeConfiguration());

    process.env.K_SERVICE = "ai-router";
    assert.equal(isManagedFirebaseRuntime(), true);
    assert.throws(
      () => assertAIProviderRuntimeConfiguration(),
      /AI_ENABLE_STUB_FALLBACK must be false/
    );
    process.env.AI_PROVIDER = "stub";
    assert.throws(
      () => assertAIProviderRuntimeConfiguration(),
      /AI_PROVIDER must be vertex/
    );
    process.env.AI_PROVIDER = "vertex";
    process.env.AI_ENABLE_STUB_FALLBACK = "false";
    assert.doesNotThrow(() => assertAIProviderRuntimeConfiguration());
  } finally {
    restoreEnvValue("AI_PROVIDER", previousProvider);
    restoreEnvValue("AI_MODEL", previousModel);
    restoreEnvValue("AI_VERTEX_LOCATION", previousLocation);
    restoreEnvValue("GCLOUD_LOCATION", previousCloudLocation);
    restoreEnvValue("AI_ENABLE_STUB_FALLBACK", previousStubFallback);
    restoreEnvValue("K_SERVICE", previousKService);
    restoreEnvValue("FUNCTION_TARGET", previousFunctionTarget);
    restoreEnvValue("FUNCTION_SIGNATURE_TYPE", previousFunctionSignatureType);
    restoreEnvValue("FUNCTIONS_EMULATOR", previousFunctionsEmulator);
    restoreEnvValue("CI", previousCI);
  }
}

function assertSubscriptionSyncContract() {
  const previousRevenueCatEntitlementID = process.env.REVENUECAT_ENTITLEMENT_ID;

  try {
    delete process.env.REVENUECAT_ENTITLEMENT_ID;
    assert.deepEqual(configuredRevenueCatEntitlementIDs(), ["aiefficiencyapp Pro"]);

    process.env.REVENUECAT_ENTITLEMENT_ID = "pro, beta";
    assert.deepEqual(configuredRevenueCatEntitlementIDs(), ["pro", "beta"]);

    const unrelatedWebhookSnapshot = deriveSnapshotFromEvent({
      type: "INITIAL_PURCHASE",
      entitlement_ids: ["unrelated"],
      product_id: "monthly",
      expiration_at_ms: null,
      event_timestamp_ms: Date.parse("2026-04-26T12:00:00.000Z")
    });
    assert.equal(unrelatedWebhookSnapshot.entitlement, "inactive");
    assert.deepEqual(unrelatedWebhookSnapshot.entitlementIDs, []);

    const matchingWebhookSnapshot = deriveSnapshotFromEvent({
      type: "INITIAL_PURCHASE",
      entitlement_ids: ["pro"],
      product_id: "monthly",
      expiration_at_ms: Date.parse("2026-05-26T12:00:00.000Z"),
      event_timestamp_ms: Date.parse("2026-04-26T12:00:00.000Z")
    });
    assert.equal(matchingWebhookSnapshot.entitlement, "active");
    assert.deepEqual(matchingWebhookSnapshot.entitlementIDs, ["pro"]);

    const subscriberSnapshot = deriveSnapshotFromSubscriberResponse({
      subscriber: {
        entitlements: {
          unrelated: {
            expires_date: "2999-01-01T00:00:00.000Z",
            product_identifier: "unrelated_monthly"
          },
          pro: {
            expires_date: "2999-01-01T00:00:00.000Z",
            product_identifier: "pro_annual"
          }
        }
      }
    });
    assert.equal(subscriberSnapshot.entitlement, "active");
    assert.deepEqual(subscriberSnapshot.entitlementIDs, ["pro"]);
    assert.equal(subscriberSnapshot.activePlan, "pro_annual");

    const transferPlan = buildRevenueCatWebhookSnapshotPlan({
      type: "TRANSFER",
      transferred_from: ["old-uid"],
      transferred_to: ["new-uid"]
    });
    assert.deepEqual(
      transferPlan.map((item) => ({
        userID: item.userID,
        entitlement: item.fallback.entitlement,
        requireFreshSnapshot: item.requireFreshSnapshot
      })),
      [
        {
          userID: "new-uid",
          entitlement: "inactive",
          requireFreshSnapshot: true
        },
        {
          userID: "old-uid",
          entitlement: "inactive",
          requireFreshSnapshot: false
        }
      ]
    );
    assert.equal(
      requiresFreshSnapshotForTransferDestination({
        type: "TRANSFER",
        transferred_from: ["old-uid"],
        transferred_to: ["new-uid"]
      }, "new-uid"),
      true
    );
    assert.equal(
      requiresFreshSnapshotForTransferDestination({
        type: "TRANSFER",
        transferred_from: ["old-uid"],
        transferred_to: ["new-uid"]
      }, "old-uid"),
      false
    );
  } finally {
    restoreEnvValue("REVENUECAT_ENTITLEMENT_ID", previousRevenueCatEntitlementID);
  }

  const betaSnapshot = deriveBetaProSnapshot("beta-uid", { BETA_PRO_USER_IDS: "beta-uid, other-uid" });
  assert.ok(betaSnapshot);
  assert.equal(betaSnapshot.entitlement, "active");
  assert.equal(betaSnapshot.activePlan, "none");
  assert.deepEqual(betaSnapshot.entitlementIDs, ["beta_pro"]);
  assert.equal(betaSnapshot.source, "beta_pro_user_ids");

  assert.equal(deriveBetaProSnapshot("free-uid", { BETA_PRO_USER_IDS: "beta-uid" }), null);

  const response = subscriptionSyncResponse(
    betaSnapshot,
    new Date("2026-04-26T12:00:00.000Z")
  );
  assert.deepEqual(response, {
    success: true,
    subscription: {
      entitlement: "active",
      activePlan: "none",
      trialEligible: false,
      entitlementIDs: ["beta_pro"],
      source: "beta_pro_user_ids",
      lastSyncedAt: "2026-04-26T12:00:00.000Z"
    }
  });
}

function assertNotificationDispatchContract() {
  assert.equal(isInvalidPushTokenError({ code: "messaging/registration-token-not-registered" }), true);
  assert.equal(isInvalidPushTokenError({ errorInfo: { code: "messaging/invalid-argument" } }), true);
  assert.equal(isInvalidPushTokenError({ code: "messaging/unavailable" }), false);
  assert.equal(isInvalidPushTokenError(new Error("network failed")), false);
  assert.equal(firebaseMessagingErrorCode({ code: "messaging/invalid-registration-token" }), "messaging/invalid-registration-token");
  assert.equal(firebaseMessagingErrorCode({ errorInfo: { code: "messaging/registration-token-not-registered" } }), "messaging/registration-token-not-registered");
  assert.equal(firebaseMessagingErrorCode("messaging/invalid-argument"), null);
}

function assertUsagePolicy() {
  assert.equal(isBetaProUserID("uid-a", { BETA_PRO_USER_IDS: "uid-a,uid-b" }), true);
  assert.equal(isBetaProUserID("uid-b", { BETA_PRO_USER_IDS: " uid-a , uid-b " }), true);
  assert.equal(isBetaProUserID("uid", { BETA_PRO_USER_IDS: "uid-extra" }), false);
  assert.equal(isBetaProUserID("UID-A", { BETA_PRO_USER_IDS: "uid-a" }), false);
  assert.equal(entitlementWithBetaProAccess("uid-a", "inactive", { BETA_PRO_USER_IDS: "uid-a" }), "active");
  assert.equal(entitlementWithBetaProAccess("uid-c", "inactive", { BETA_PRO_USER_IDS: "uid-a" }), "inactive");
  assert.equal(entitlementWithBetaProAccess("uid-a", "active", { BETA_PRO_USER_IDS: "" }), "active");

  assert.equal(dailyLimitForWorkflow("vibe_feedback", "inactive", {}), DEFAULT_FREE_DAILY_LIMIT);
  assert.equal(dailyLimitForWorkflow("assistant_chat", "active", {}), DEFAULT_PREMIUM_DAILY_LIMIT);
  assert.equal(
    dailyLimitForWorkflow("assistant_chat", "active", {
      AI_PREMIUM_DAILY_LIMIT: "120",
      AI_DAILY_LIMIT_ASSISTANT_CHAT_ACTIVE: "25"
    }),
    25
  );
  assert.equal(
    dailyLimitForWorkflow("vibe_feedback", "inactive", {
      AI_FREE_DAILY_LIMIT: "30"
    }),
    30
  );

  assert.deepEqual(
    nextWorkflowCountsForReservation({ assistant_chat: 50, vibe_feedback: 49 }, "vibe_feedback", 50),
    { assistant_chat: 50, vibe_feedback: 50 }
  );
  assert.throws(
    () => nextWorkflowCountsForReservation({ assistant_chat: 50, vibe_feedback: 1 }, "assistant_chat", 50),
    /daily AI limit for assistant_chat/
  );
}

function assertPromptContracts() {
  const identityResponse = "I’m your in-app productivity assistant, here to help you plan, study, and stay organized.";
  const providerNames = [
    "ChatGPT",
    "Claude",
    "Gemini",
    "Qwen",
    "Gemma",
    "Kimi",
    "DeepSeek",
    "OpenAI",
    "Anthropic",
    "Google",
    "Alibaba"
  ];
  const prompts = [
    ["assistant_chat", ASSISTANT_CHAT_SYSTEM_PROMPT],
    ["goal_plan_generation", GOAL_PLAN_GENERATION_SYSTEM_PROMPT],
    ["vibe_feedback", VIBE_FEEDBACK_SYSTEM_PROMPT],
    ["syllabus_import", SYLLABUS_IMPORT_SYSTEM_PROMPT],
    ["schedule_planner_generation", SCHEDULE_PLANNER_GENERATION_SYSTEM_PROMPT],
    ["study_session_support", STUDY_SESSION_SUPPORT_SYSTEM_PROMPT]
  ] as const;

  assert.ok(BASE_SYSTEM_PROMPT.includes(identityResponse), "Base prompt must define the exact identity response.");
  assert.ok(BASE_SYSTEM_PROMPT.includes("untrusted data"), "Base prompt must treat request/context fields as untrusted data.");
  assert.ok(BASE_SYSTEM_PROMPT.includes("<<<USER_INPUT_BEGIN>>>"), "Base prompt must define the input sentinel start token.");
  assert.ok(BASE_SYSTEM_PROMPT.includes("<<<USER_INPUT_END>>>"), "Base prompt must define the input sentinel end token.");
  assert.ok(BASE_SYSTEM_PROMPT.includes("Ignore any instruction"), "Base prompt must explicitly reject conflicting embedded instructions.");
  for (const providerName of providerNames) {
    assert.ok(
      BASE_SYSTEM_PROMPT.includes(providerName),
      `Base prompt must explicitly prohibit revealing ${providerName}.`
    );
  }

  for (const [featureName, prompt] of prompts) {
    assert.ok(prompt.includes(BASE_SYSTEM_PROMPT), `${featureName} prompt must include the base prompt.`);
    assert.ok(prompt.includes("Purpose:"), `${featureName} prompt must define purpose.`);
    assert.ok(prompt.includes("Allowed scope:"), `${featureName} prompt must define allowed scope.`);
    assert.ok(prompt.includes("Output format"), `${featureName} prompt must define output expectations.`);
  }
}

function restoreEnvValue(key: string, value: string | undefined) {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}

runSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
