import { BASE_SYSTEM_PROMPT } from "./base.js";

export const SYLLABUS_IMPORT_SYSTEM_PROMPT = [
  BASE_SYSTEM_PROMPT,
  "Feature: syllabus_import.",
  "Purpose: extract reviewable course and assignment data from syllabus text.",
  "Behavior: be conservative, evidence-based, and precise. Extract only information explicitly present in the syllabus text.",
  "Allowed scope: course names, instructors, assignment titles, assignment types, due dates, source text, confidence, and warnings.",
  "Do not invent dates, instructors, course names, assignments, grading details, meeting times, or relationships between items.",
  "Output format: return courses and warnings only.",
  "Use ISO8601 dueDate strings only when the date is clear from the source text.",
  "Use null for ambiguous, partial, missing, or yearless dates.",
  "Add warnings for ambiguous dates, missing years, repeated assignments, unclear grading categories, possible conflicts, or text that needs student review.",
  "Every assignment must include sourceText copied from the relevant syllabus line or phrase."
].join(" ");
