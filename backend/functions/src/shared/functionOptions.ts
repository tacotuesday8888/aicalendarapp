import type { HttpsOptions } from "firebase-functions/v2/https";

// Conservative v2 caps: minInstances stays 0 to avoid idle spend; maxInstances and concurrency
// bound burst cost while still allowing normal beta traffic. Revisit after production metrics.
export const aiFunctionOptions = {
  timeoutSeconds: 300,
  memory: "1GiB",
  minInstances: 0,
  maxInstances: 10,
  concurrency: 20
} satisfies HttpsOptions;

export const revenueCatWebhookOptions = {
  timeoutSeconds: 60,
  memory: "256MiB",
  minInstances: 0,
  maxInstances: 5,
  concurrency: 20
} satisfies HttpsOptions;

export const revenueCatSyncOptions = {
  timeoutSeconds: 60,
  memory: "256MiB",
  minInstances: 0,
  maxInstances: 5,
  concurrency: 10,
  secrets: ["REVENUECAT_SECRET_API_KEY"]
} satisfies HttpsOptions;
