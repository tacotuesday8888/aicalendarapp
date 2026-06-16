import { HttpsError } from "firebase-functions/v2/https";

import type { AIWorkflow } from "./schemas.js";

export type SubscriptionEntitlement = "active" | "inactive";

export const DEFAULT_FREE_DAILY_LIMIT = 50;
export const DEFAULT_PREMIUM_DAILY_LIMIT = 200;

export function entitlementWithBetaProAccess(
  userID: string,
  subscriptionEntitlement: SubscriptionEntitlement,
  env: NodeJS.ProcessEnv = process.env
): SubscriptionEntitlement {
  if (subscriptionEntitlement === "active" || isBetaProUserID(userID, env)) {
    return "active";
  }

  return "inactive";
}

export function isBetaProUserID(userID: string, env: NodeJS.ProcessEnv = process.env): boolean {
  const rawValue = env.BETA_PRO_USER_IDS;
  if (!rawValue) {
    return false;
  }

  return rawValue
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .some((listedUserID) => listedUserID === userID);
}

export function dailyLimitForWorkflow(
  workflow: AIWorkflow,
  entitlement: SubscriptionEntitlement,
  env: NodeJS.ProcessEnv = process.env
): number {
  const specificKey = `AI_DAILY_LIMIT_${workflow.toUpperCase()}_${entitlement.toUpperCase()}`;
  const planKey = entitlement === "active" ? "AI_PREMIUM_DAILY_LIMIT" : "AI_FREE_DAILY_LIMIT";
  const fallback = entitlement === "active" ? DEFAULT_PREMIUM_DAILY_LIMIT : DEFAULT_FREE_DAILY_LIMIT;
  return positiveInteger(env[specificKey]) ?? positiveInteger(env[planKey]) ?? fallback;
}

export function nextWorkflowCountsForReservation(
  workflowCounts: Partial<Record<AIWorkflow, number>>,
  workflow: AIWorkflow,
  maxPerDay: number
): Partial<Record<AIWorkflow, number>> {
  const workflowCount = numberValue(workflowCounts[workflow]);

  if (workflowCount >= maxPerDay) {
    throw new HttpsError(
      "resource-exhausted",
      `You've reached the daily AI limit for ${workflow} (${maxPerDay} requests). Try again tomorrow.`
    );
  }

  return {
    ...workflowCounts,
    [workflow]: workflowCount + 1
  };
}

export function workflowCountsValue(value: unknown): Partial<Record<AIWorkflow, number>> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(value).filter((entry): entry is [AIWorkflow, number] => typeof entry[1] === "number")
  ) as Partial<Record<AIWorkflow, number>>;
}

export function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function positiveInteger(rawValue: string | undefined): number | undefined {
  if (!rawValue) {
    return undefined;
  }

  const parsed = Number.parseInt(rawValue, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
