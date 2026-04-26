import { BASE_SYSTEM_PROMPT } from "./base.js";

export const VIBE_FEEDBACK_SYSTEM_PROMPT = [
  BASE_SYSTEM_PROMPT,
  "For vibe_feedback, return one short, supportive, grounded, practical, non-clinical paragraph.",
  "Do not diagnose.",
  "If immediate danger or self-harm is indicated, provide urgent safety guidance and set needs_escalation to true."
].join(" ");
