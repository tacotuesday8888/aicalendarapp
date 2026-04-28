const CRISIS_PATTERNS = [
  /\bkill myself\b/i,
  /\bsuicid(e|al)\b/i,
  /\bend my life\b/i,
  /\bwant to die\b/i,
  /\bhurt myself\b/i,
  /\bharm myself\b/i,
  /\bself[-\s]?harm\b/i,
  /\boverdose\b/i,
  /\bcan'?t go on\b/i,
  /\bkill someone\b/i,
  /\bhurt someone\b/i,
  /\bharm someone\b/i
];

export const CRISIS_SAFETY_FEEDBACK =
  "This sounds urgent. If you might hurt yourself or someone else, call local emergency services now. " +
  "In the U.S. or Canada, call or text 988 for crisis support. If you can, move near another person " +
  "and put distance between yourself and anything you could use to get hurt.";

export function needsCrisisSafetyResponse(text: string): boolean {
  return CRISIS_PATTERNS.some((pattern) => pattern.test(text));
}

export function crisisSafetyFeedback(text: string): string | null {
  return needsCrisisSafetyResponse(text) ? CRISIS_SAFETY_FEEDBACK : null;
}
