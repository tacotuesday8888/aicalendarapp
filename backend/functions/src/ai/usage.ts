import { HttpsError } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";

import { db, serverTimestamp, userDoc, userScopedCollection } from "../shared/firestore.js";
import { getAIModelName, getAIProviderMode } from "./config.js";
import type { AIWorkflow } from "./schemas.js";
import {
  dailyLimitForWorkflow,
  entitlementWithBetaProAccess,
  nextWorkflowCountsForReservation,
  numberValue,
  type SubscriptionEntitlement,
  workflowCountsValue
} from "./usagePolicy.js";

const DEFAULT_DAILY_LIMIT = 50;
const PREMIUM_WORKFLOWS = new Set<AIWorkflow>(["assistant_chat", "goal_plan_generation", "syllabus_import"]);

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

export async function logAIUsageBestEffort(
  userID: string,
  workflow: AIWorkflow,
  status: "success" | "error",
  metadata: Record<string, unknown> = {},
  logUsage: typeof logAIUsage = logAIUsage
): Promise<boolean> {
  try {
    await logUsage(userID, workflow, status, metadata);
    return true;
  } catch (error) {
    logger.warn("Failed to log AI usage event.", {
      userID,
      workflow,
      status,
      errorName: error instanceof Error ? error.name : typeof error,
      errorMessage: error instanceof Error ? error.message : null
    });
    return false;
  }
}

async function reserveAIRateLimit(userID: string, workflow: AIWorkflow, maxPerDay: number) {
  const day = utcDayKey(new Date());
  const quotaRef = userScopedCollection(userID, "aiUsageDaily").doc(day);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(quotaRef);
    const existingCount = numberValue(snapshot.get("count"));
    const workflowCounts = workflowCountsValue(snapshot.get("workflowCounts"));
    const nextWorkflowCounts = nextWorkflowCountsForReservation(workflowCounts, workflow, maxPerDay);

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
  const subscriptionEntitlement = snapshot.get("entitlement") === "active" ? "active" : "inactive";
  return entitlementWithBetaProAccess(userID, subscriptionEntitlement);
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

function utcDayKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}
