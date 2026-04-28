import { HttpsError } from "firebase-functions/v2/https";

import { db, serverTimestamp, userDoc, userScopedCollection } from "../shared/firestore.js";
import { getAIModelName, getAIProviderMode } from "./config.js";
import type { AIWorkflow } from "./schemas.js";

const DEFAULT_DAILY_LIMIT = 50;
const PREMIUM_WORKFLOWS = new Set<AIWorkflow>(["assistant_chat", "goal_plan_generation", "syllabus_import"]);

type SubscriptionEntitlement = "active" | "inactive";

export async function authorizeAndReserveAIUsage(userID: string, workflow: AIWorkflow) {
  const entitlement = await currentSubscriptionEntitlement(userID);
  enforceAIPremiumAccessForEntitlement(entitlement, workflow);
  await reserveAIRateLimit(userID, workflow, dailyLimitForWorkflow(workflow, entitlement));
}

export async function enforceAIRateLimit(
  userID: string,
  workflow: AIWorkflow = "vibe_feedback",
  maxPerDay: number = DEFAULT_DAILY_LIMIT
) {
  await reserveAIRateLimit(userID, workflow, maxPerDay);
}

export async function enforceAIPremiumAccess(userID: string, workflow: AIWorkflow) {
  const entitlement = await currentSubscriptionEntitlement(userID);
  enforceAIPremiumAccessForEntitlement(entitlement, workflow);
}

export async function logAIUsage(
  userID: string,
  workflow: AIWorkflow,
  status: "success" | "error",
  metadata: Record<string, unknown> = {}
) {
  await userScopedCollection(userID, "aiUsage").add({
    workflow,
    status,
    provider: getAIProviderMode(),
    model: getAIProviderMode() === "vertex" ? getAIModelName() : "stub",
    ...metadata,
    createdAt: serverTimestamp()
  });
}

async function reserveAIRateLimit(userID: string, workflow: AIWorkflow, maxPerDay: number) {
  const day = utcDayKey(new Date());
  const quotaRef = userScopedCollection(userID, "aiUsageDaily").doc(day);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(quotaRef);
    const existingCount = numberValue(snapshot.get("count"));
    const workflowCounts = workflowCountsValue(snapshot.get("workflowCounts"));
    const workflowCount = numberValue(workflowCounts[workflow]);

    if (existingCount >= maxPerDay) {
      throw new HttpsError(
        "resource-exhausted",
        `You've reached the daily AI limit (${maxPerDay} requests). Try again tomorrow.`
      );
    }

    const nextWorkflowCounts = {
      ...workflowCounts,
      [workflow]: workflowCount + 1
    };

    transaction.set(
      quotaRef,
      {
        userID,
        day,
        count: existingCount + 1,
        limit: maxPerDay,
        workflowCounts: nextWorkflowCounts,
        window: "utc_day",
        createdAt: snapshot.exists ? snapshot.get("createdAt") ?? serverTimestamp() : serverTimestamp(),
        updatedAt: serverTimestamp()
      },
      { merge: true }
    );
  });
}

async function currentSubscriptionEntitlement(userID: string): Promise<SubscriptionEntitlement> {
  const snapshot = await userDoc(userID).collection("subscriptions").doc("current").get();
  return snapshot.get("entitlement") === "active" ? "active" : "inactive";
}

function enforceAIPremiumAccessForEntitlement(entitlement: SubscriptionEntitlement, workflow: AIWorkflow) {
  if (!PREMIUM_WORKFLOWS.has(workflow) || entitlement === "active") {
    return;
  }

  throw new HttpsError(
    "permission-denied",
    "A Pro subscription is required for this AI feature."
  );
}

function dailyLimitForWorkflow(workflow: AIWorkflow, entitlement: SubscriptionEntitlement): number {
  const specificKey = `AI_DAILY_LIMIT_${workflow.toUpperCase()}_${entitlement.toUpperCase()}`;
  const planKey = entitlement === "active" ? "AI_PREMIUM_DAILY_LIMIT" : "AI_FREE_DAILY_LIMIT";
  return positiveInteger(process.env[specificKey]) ?? positiveInteger(process.env[planKey]) ?? DEFAULT_DAILY_LIMIT;
}

function utcDayKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function positiveInteger(rawValue: string | undefined): number | undefined {
  if (!rawValue) {
    return undefined;
  }

  const parsed = Number.parseInt(rawValue, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function workflowCountsValue(value: unknown): Partial<Record<AIWorkflow, number>> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(value).filter((entry): entry is [AIWorkflow, number] => typeof entry[1] === "number")
  ) as Partial<Record<AIWorkflow, number>>;
}
