import type { VibeFeedbackResult } from "./schemas.js";

// Seeded from public crisis-screening/warning-sign language published by 988 Lifeline,
// NY OMH 988, and NIMH ASQ translations. Keep these high-signal to limit false positives.
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
  /\bharm someone\b/i,
  /\bquiero morir\b/i,
  /\bno quiero vivir\b/i,
  /\bme quiero morir\b/i,
  /\bme (quiero|voy a) matar\b/i,
  /\bme (quiero|voy a) suicidar\b/i,
  /\b(matarme|suicidarme|suicidarse)\b/i,
  /\btengo miedo de suicidarme\b/i,
  /\bhacerme daño\b/i,
  /\blastimarme\b/i,
  /\bautolesi[oó]n\b/i,
  /\bmatar a alguien\b/i,
  /\b(lastimar|hacerle daño) a alguien\b/i,
  /\bje veux mourir\b/i,
  /\bveux mourir\b/i,
  /\benvie de mourir\b/i,
  /\bplus envie de vivre\b/i,
  /\bpas envie de vivre\b/i,
  /\bme suicider\b/i,
  /\bsuicidaire\b/i,
  /\bme tuer\b/i,
  /\bmettre fin [aà] ma vie\b/i,
  /\bme faire du mal\b/i,
  /\bautomutilation\b/i,
  /\btuer quelqu['’]?un\b/i,
  /\bfaire du mal [aà] quelqu['’]?un\b/i,
  /想死/,
  /不想活/,
  /不想继续活/,
  /希望自己死了/,
  /自杀|自殺/,
  /结束生命|結束生命/,
  /杀了自己|殺了自己/,
  /伤害自己|傷害自己/,
  /自残|自殘/,
  /杀人|殺人/,
  /伤害别人|傷害別人/
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

export function reviewVibeFeedbackForCrisis(result: VibeFeedbackResult): VibeFeedbackResult {
  const safetyFeedback = crisisSafetyFeedback(result.feedback);
  if (!safetyFeedback) {
    return result;
  }

  return {
    feedback: safetyFeedback,
    needs_escalation: true
  };
}
