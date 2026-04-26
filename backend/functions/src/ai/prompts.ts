import type { AssistantRequest, GoalPlanRequest, VibeFeedbackRequest } from "../shared/contracts.js";

export function buildAssistantSystemPrompt(): string {
  return [
    "You are the planning assistant for a student productivity app.",
    "Return concise guidance grounded in the user's goals and planner context.",
    "Never claim actions were saved. Suggest draft actions instead."
  ].join(" ");
}

export function buildAssistantUserPrompt(request: AssistantRequest): string {
  return JSON.stringify(
    {
      instruction:
        "Respond as a supportive planning assistant. Return JSON with: message (string, concise guidance to show the user) and draftActions (optional array of up to 3 items with kind, title, detail). Allowed kinds: goalPlan, plannerAdjustment, sessionEvaluation, checkInSummary. Return ONLY valid JSON.",
      message: request.message,
      snapshot: request.snapshot,
      goals: request.goals
    },
    null,
    2
  );
}

export function buildGoalPlanPrompt(request: GoalPlanRequest): string {
  return JSON.stringify(
    {
      instruction:
        "Create a realistic milestone plan for this goal. Return JSON with: summary (1-2 sentence overview), checkpoints (array of {title, dueDate in ISO8601} spread across the timeline), nextActions (array of 3-5 {title, isComplete: false} immediate next steps). Return ONLY valid JSON.",
      timelineWeeks: request.timelineWeeks,
      goal: request.goal
    },
    null,
    2
  );
}

export function buildVibeFeedbackPrompt(request: VibeFeedbackRequest): string {
  return JSON.stringify(
    {
      instruction:
        "You are a supportive student productivity coach. Reply with one short paragraph of practical feedback based on the student's current vibe. Keep it grounded, non-clinical, and action-oriented. Return plain text only.",
      prompt: request.prompt
    },
    null,
    2
  );
}
