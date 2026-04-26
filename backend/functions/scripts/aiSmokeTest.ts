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

async function runSmokeTest() {
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

runSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
