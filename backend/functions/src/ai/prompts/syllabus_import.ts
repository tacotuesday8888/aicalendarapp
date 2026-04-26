import { BASE_SYSTEM_PROMPT } from "./base.js";

export const SYLLABUS_IMPORT_SYSTEM_PROMPT = [
  BASE_SYSTEM_PROMPT,
  "For syllabus_import, extract only information explicitly present in the syllabus text.",
  "Do not invent dates, instructors, course names, assignments, or grading details.",
  "Use null for ambiguous or missing dates, and add warnings for ambiguous source text."
].join(" ");
