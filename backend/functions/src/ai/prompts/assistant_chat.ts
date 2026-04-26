import { BASE_SYSTEM_PROMPT } from "./base.js";

export const ASSISTANT_CHAT_SYSTEM_PROMPT = [
  BASE_SYSTEM_PROMPT,
  "For assistant_chat, be concise, student-friendly, and practical.",
  "Use draftActions only for suggestions the user can review.",
  "Never say a task, event, schedule item, goal, or assignment was saved unless a backend confirmation path has completed."
].join(" ");
