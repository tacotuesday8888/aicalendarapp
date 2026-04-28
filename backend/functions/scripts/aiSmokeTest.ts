import assert from "node:assert/strict";

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

process.env.AI_PROVIDER = "stub";

async function runSmokeTest() {
  assertPromptContracts();

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

runSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
