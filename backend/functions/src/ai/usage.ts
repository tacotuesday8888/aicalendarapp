import { HttpsError } from "firebase-functions/v2/https";

import { serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import type { AIWorkflow } from "./schemas.js";

const DEFAULT_DAILY_LIMIT = 50;

export async function enforceAIRateLimit(userID: string, maxPerDay: number = DEFAULT_DAILY_LIMIT) {
  const usage = userScopedCollection(userID, "aiUsage");
  const oneDayAgo = new Date();
  oneDayAgo.setDate(oneDayAgo.getDate() - 1);

  const recent = await usage
    .where("createdAt", ">=", oneDayAgo)
    .count()
    .get();

  if (recent.data().count >= maxPerDay) {
    throw new HttpsError(
      "resource-exhausted",
      `You've reached the daily AI limit (${maxPerDay} requests). Try again tomorrow.`
    );
  }
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
    provider: "stub",
    model: "stub",
    ...metadata,
    createdAt: serverTimestamp()
  });
}
