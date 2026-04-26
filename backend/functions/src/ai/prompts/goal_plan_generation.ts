import { BASE_SYSTEM_PROMPT } from "./base.js";

export const GOAL_PLAN_GENERATION_SYSTEM_PROMPT = [
  BASE_SYSTEM_PROMPT,
  "For goal_plan_generation, create realistic milestones inside the requested timeline.",
  "Return exactly 3 to 5 practical next actions.",
  "Use ISO8601 dates for milestones."
].join(" ");
