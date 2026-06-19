import { HttpsError, onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { timingSafeEqual } from "node:crypto";

import { db, serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import { revenueCatSyncOptions, revenueCatWebhookOptions } from "../shared/functionOptions.js";
import { userJobRequestSchema } from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";
import { isBetaProUserID } from "../ai/usagePolicy.js";

type RevenueCatWebhookEvent = {
  id?: string;
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  transferred_from?: string[];
  transferred_to?: string[];
  entitlement_ids?: string[] | null;
  product_id?: string | null;
  expiration_at_ms?: number | null;
  event_timestamp_ms?: number | null;
  environment?: string;
  store?: string;
};

type RevenueCatSubscriberEntitlement = {
  expires_date?: string | null;
  product_identifier?: string | null;
};

type RevenueCatSubscriberResponse = {
  subscriber?: {
    entitlements?: Record<string, RevenueCatSubscriberEntitlement>;
  };
};

type SubscriptionSnapshot = {
  entitlement: "active" | "inactive";
  activePlan: string;
  entitlementIDs: string[];
  source: "revenuecat_rest_api" | "revenuecat_webhook_fallback" | "revenuecat_transfer" | "beta_pro_user_ids";
};

type SubscriptionSyncResponse = {
  success: true;
  subscription: {
    entitlement: "active" | "inactive";
    activePlan: "monthly" | "annual" | "none";
    trialEligible: boolean;
    entitlementIDs: string[];
    source: SubscriptionSnapshot["source"];
    lastSyncedAt: string;
  };
};

type SnapshotLookupOptions = {
  requireFreshSnapshot?: boolean;
};

type RevenueCatWebhookSnapshotPlanItem = {
  userID: string;
  fallback: SubscriptionSnapshot;
  requireFreshSnapshot: boolean;
};

const DEFAULT_REVENUECAT_ENTITLEMENT_ID = "aiefficiencyapp Pro";

export function configuredRevenueCatEntitlementIDs(env: NodeJS.ProcessEnv = process.env): string[] {
  const rawValue = env.REVENUECAT_ENTITLEMENT_ID ?? env.REVENUECAT_ENTITLEMENT_IDS ?? DEFAULT_REVENUECAT_ENTITLEMENT_ID;
  return rawValue
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
}

function uniqueUserIDs(values: Array<string | undefined>): string[] {
  return Array.from(new Set(
    values
      .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
      .map((value) => value.trim())
  ));
}

function parseTimestampMs(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function parseIsoTimestamp(value: string | null | undefined): number | null {
  if (!value) {
    return null;
  }

  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function deriveSnapshotFromEvent(event: RevenueCatWebhookEvent): SubscriptionSnapshot {
  const allowedEntitlementIDs = new Set(configuredRevenueCatEntitlementIDs());
  const entitlementIDs = Array.isArray(event.entitlement_ids)
    ? event.entitlement_ids.filter((value): value is string =>
      typeof value === "string" && value.length > 0 && allowedEntitlementIDs.has(value)
    )
    : [];
  const hasEntitlement = entitlementIDs.length > 0;
  const expirationAtMs = parseTimestampMs(event.expiration_at_ms);
  const referenceMs = parseTimestampMs(event.event_timestamp_ms) ?? Date.now();

  let isActive = false;
  switch (event.type) {
  case "EXPIRATION":
    isActive = false;
    break;
  case "CANCELLATION":
    isActive = hasEntitlement && expirationAtMs !== null && expirationAtMs > referenceMs;
    break;
  case "BILLING_ISSUE":
  case "SUBSCRIPTION_PAUSED":
    isActive = hasEntitlement;
    break;
  default:
    isActive = hasEntitlement && (expirationAtMs === null || expirationAtMs > referenceMs);
    break;
  }

  return {
    entitlement: isActive ? "active" : "inactive",
    activePlan: isActive && event.product_id ? event.product_id : "none",
    entitlementIDs,
    source: "revenuecat_webhook_fallback"
  };
}

function deriveTransferSourceSnapshot(): SubscriptionSnapshot {
  return {
    entitlement: "inactive",
    activePlan: "none",
    entitlementIDs: [],
    source: "revenuecat_transfer"
  };
}

function deriveTransferDestinationSnapshot(event: RevenueCatWebhookEvent): SubscriptionSnapshot {
  const snapshot = deriveSnapshotFromEvent(event);
  return {
    ...snapshot,
    source: "revenuecat_transfer"
  };
}

export function deriveBetaProSnapshot(userID: string, env: NodeJS.ProcessEnv = process.env): SubscriptionSnapshot | null {
  if (!isBetaProUserID(userID, env)) {
    return null;
  }

  return {
    entitlement: "active",
    activePlan: "none",
    entitlementIDs: ["beta_pro"],
    source: "beta_pro_user_ids"
  };
}

export function requiresFreshSnapshotForTransferDestination(event: RevenueCatWebhookEvent, userID: string): boolean {
  const transferredToUserIDs = uniqueUserIDs(Array.isArray(event.transferred_to) ? event.transferred_to : []);
  return transferredToUserIDs.includes(userID.trim());
}

export function buildRevenueCatWebhookSnapshotPlan(event: RevenueCatWebhookEvent): RevenueCatWebhookSnapshotPlanItem[] {
  const primaryUserIDs = uniqueUserIDs([
    event.app_user_id,
    event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : [])
  ]);
  const transferredFromUserIDs = uniqueUserIDs(Array.isArray(event.transferred_from) ? event.transferred_from : []);
  const transferredToUserIDs = uniqueUserIDs(Array.isArray(event.transferred_to) ? event.transferred_to : []);

  return [
    ...primaryUserIDs.map((userID) => ({
      userID,
      fallback: deriveSnapshotFromEvent(event),
      requireFreshSnapshot: false
    })),
    ...transferredToUserIDs.map((userID) => ({
      userID,
      fallback: deriveTransferDestinationSnapshot(event),
      requireFreshSnapshot: requiresFreshSnapshotForTransferDestination(event, userID)
    })),
    ...transferredFromUserIDs.map((userID) => ({
      userID,
      fallback: deriveTransferSourceSnapshot(),
      requireFreshSnapshot: false
    }))
  ];
}

function expirationTimestampForEntitlement(entitlement: RevenueCatSubscriberEntitlement): number {
  return parseIsoTimestamp(entitlement.expires_date) ?? Number.MAX_SAFE_INTEGER;
}

export function deriveSnapshotFromSubscriberResponse(response: RevenueCatSubscriberResponse): SubscriptionSnapshot {
  const allowedEntitlementIDs = new Set(configuredRevenueCatEntitlementIDs());
  const entitlements = response.subscriber?.entitlements ?? {};
  const activeEntitlements = Object.entries(entitlements).filter(([identifier, entitlement]) => {
    if (!allowedEntitlementIDs.has(identifier)) {
      return false;
    }

    const expiresAt = parseIsoTimestamp(entitlement.expires_date);
    return expiresAt === null || expiresAt > Date.now();
  });

  if (activeEntitlements.length === 0) {
    return {
      entitlement: "inactive",
      activePlan: "none",
      entitlementIDs: [],
      source: "revenuecat_rest_api"
    };
  }

  activeEntitlements.sort((lhs, rhs) => expirationTimestampForEntitlement(rhs[1]) - expirationTimestampForEntitlement(lhs[1]));
  const primaryEntry = activeEntitlements[0];
  if (!primaryEntry) {
    return {
      entitlement: "inactive",
      activePlan: "none",
      entitlementIDs: [],
      source: "revenuecat_rest_api"
    };
  }

  const [, primaryEntitlement] = primaryEntry;

  return {
    entitlement: "active",
    activePlan: primaryEntitlement.product_identifier ?? "unknown",
    entitlementIDs: activeEntitlements.map(([identifier]) => identifier),
    source: "revenuecat_rest_api"
  };
}

async function fetchRevenueCatSubscriberSnapshot(appUserID: string, secretApiKey: string): Promise<SubscriptionSnapshot> {
  const response = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserID)}`, {
    headers: {
      Authorization: `Bearer ${secretApiKey}`,
      Accept: "application/json"
    }
  });

  if (!response.ok) {
    throw new Error(`RevenueCat subscriber lookup failed with status ${response.status}.`);
  }

  const payload = await response.json() as RevenueCatSubscriberResponse;
  return deriveSnapshotFromSubscriberResponse(payload);
}

async function persistSubscriptionSnapshot(
  userID: string,
  snapshot: SubscriptionSnapshot,
  event: RevenueCatWebhookEvent,
  eventID: string
): Promise<void> {
  await userScopedCollection(userID, "subscriptions").doc("current").set(subscriptionSnapshotWriteData(snapshot, event, eventID), { merge: true });
}

function subscriptionSnapshotWriteData(
  snapshot: SubscriptionSnapshot,
  event: RevenueCatWebhookEvent,
  eventID: string
): Record<string, unknown> {
  return {
    entitlement: snapshot.entitlement,
    activePlan: appPlanFromProductID(snapshot.activePlan),
    entitlementIDs: snapshot.entitlementIDs,
    source: snapshot.source,
    lastEventID: eventID,
    lastEventType: event.type ?? "unknown",
    revenueCatEnvironment: event.environment ?? null,
    revenueCatProductID: snapshot.activePlan !== "none" ? snapshot.activePlan : event.product_id ?? null,
    revenueCatStore: event.store ?? null,
    updatedAt: serverTimestamp()
  };
}

export function subscriptionSyncResponse(
  snapshot: SubscriptionSnapshot,
  syncedAt: Date = new Date()
): SubscriptionSyncResponse {
  return {
    success: true,
    subscription: {
      entitlement: snapshot.entitlement,
      activePlan: appPlanFromProductID(snapshot.activePlan),
      trialEligible: snapshot.entitlement !== "active",
      entitlementIDs: snapshot.entitlementIDs,
      source: snapshot.source,
      lastSyncedAt: syncedAt.toISOString()
    }
  };
}

export const syncRevenueCatSubscription = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const secretApiKey = process.env.REVENUECAT_SECRET_API_KEY?.trim();
  const betaSnapshot = deriveBetaProSnapshot(userID);
  const syncEventID = `subscriber-sync-${userID}-${Date.now()}`;

  if (betaSnapshot) {
    await persistSubscriptionSnapshot(
      userID,
      betaSnapshot,
      {
        id: syncEventID,
        type: "BETA_PRO_SYNC"
      },
      syncEventID
    );

    return subscriptionSyncResponse(betaSnapshot);
  }

  if (!secretApiKey) {
    throw new HttpsError("failed-precondition", "RevenueCat subscriber sync is not configured.");
  }

  const snapshot = await fetchRevenueCatSubscriberSnapshot(userID, secretApiKey);
  await persistSubscriptionSnapshot(
    userID,
    snapshot,
    {
      id: syncEventID,
      type: "SUBSCRIBER_SYNC"
    },
    syncEventID
  );

  return subscriptionSyncResponse(snapshot);
}, revenueCatSyncOptions);

export const revenueCatWebhook = onRequest({
  ...revenueCatWebhookOptions,
  secrets: ["REVENUECAT_WEBHOOK_SECRET", "REVENUECAT_SECRET_API_KEY"]
}, async (request, response) => {
  if (request.method !== "POST") {
    response.status(405).send({ success: false, reason: "Only POST requests are supported." });
    return;
  }

  const expectedAuthorizationHeader = process.env.REVENUECAT_WEBHOOK_SECRET?.trim();

  if (!expectedAuthorizationHeader) {
    logger.error(
      "revenueCatWebhook called without REVENUECAT_WEBHOOK_SECRET set. " +
      "Refusing to process events. Set the secret with `firebase functions:secrets:set REVENUECAT_WEBHOOK_SECRET` " +
      "or define it in the Functions runtime environment."
    );
    response.status(503).send({
      success: false,
      reason: "Webhook is not configured. REVENUECAT_WEBHOOK_SECRET is missing on the server."
    });
    return;
  }

  const providedAuthorizationHeader = (request.header("Authorization") ?? "").trim();
  if (!constantTimeEquals(providedAuthorizationHeader, expectedAuthorizationHeader)) {
    response.status(401).send({ success: false, reason: "Invalid webhook authorization header." });
    return;
  }

  const event = (request.body?.event ?? request.body ?? {}) as RevenueCatWebhookEvent;
  const eventType = event.type ?? "UNKNOWN";
  const eventID = String(event.id ?? event.event_timestamp_ms ?? `${eventType}-${Date.now()}`);

  if (eventType === "TEST") {
    response.status(200).send({ success: true, test: true });
    return;
  }

  const eventRef = db.collection("_revenuecatWebhookEvents").doc(eventID);
  if ((await eventRef.get()).exists) {
    response.status(200).send({ success: true, duplicate: true });
    return;
  }

  const snapshotPlan = buildRevenueCatWebhookSnapshotPlan(event);
  const affectedUserIDs = uniqueUserIDs(snapshotPlan.map((item) => item.userID));

  if (affectedUserIDs.length === 0) {
    response.status(400).send({ success: false, reason: "Missing RevenueCat user identifiers." });
    return;
  }

  const secretApiKey = process.env.REVENUECAT_SECRET_API_KEY?.trim();
  const snapshotCache = new Map<string, SubscriptionSnapshot>();

  const snapshotFor = async (
    userID: string,
    fallback: SubscriptionSnapshot,
    options: SnapshotLookupOptions = {}
  ): Promise<SubscriptionSnapshot> => {
    const cached = snapshotCache.get(userID);
    if (cached) {
      return cached;
    }

    let snapshot = fallback;
    if (secretApiKey) {
      try {
        snapshot = await fetchRevenueCatSubscriberSnapshot(userID, secretApiKey);
      } catch (error) {
        logger.warn(options.requireFreshSnapshot
          ? "RevenueCat subscriber lookup failed; transfer destination event will be retried."
          : "RevenueCat subscriber lookup failed; falling back to webhook event payload.", {
          eventID,
          eventType,
          userID,
          error: error instanceof Error ? error.message : String(error)
        });
        if (options.requireFreshSnapshot) {
          throw new HttpsError(
            "unavailable",
            "RevenueCat subscriber lookup is required before processing transfer destination events."
          );
        }
      }
    } else if (options.requireFreshSnapshot) {
      throw new HttpsError(
        "failed-precondition",
        "REVENUECAT_SECRET_API_KEY is required before processing transfer destination events."
      );
    }

    snapshotCache.set(userID, snapshot);
    return snapshot;
  };

  let resolvedSnapshots: Array<{ userID: string; snapshot: SubscriptionSnapshot }>;
  try {
    resolvedSnapshots = await Promise.all(snapshotPlan.map(async (item) => ({
      userID: item.userID,
      snapshot: await snapshotFor(item.userID, item.fallback, {
        requireFreshSnapshot: item.requireFreshSnapshot
      })
    })));
  } catch (error) {
    logger.error("RevenueCat webhook could not persist a verified subscription snapshot.", {
      eventID,
      eventType,
      error: error instanceof Error ? error.message : String(error)
    });
    response.status(503).send({
      success: false,
      reason: "RevenueCat subscriber snapshot is required before this event can be processed."
    });
    return;
  }

  const snapshotsByUserID = new Map<string, SubscriptionSnapshot>();
  for (const item of resolvedSnapshots) {
    snapshotsByUserID.set(item.userID, item.snapshot);
  }

  const batch = db.batch();
  for (const [userID, snapshot] of snapshotsByUserID) {
    batch.set(
      userScopedCollection(userID, "subscriptions").doc("current"),
      subscriptionSnapshotWriteData(snapshot, event, eventID),
      { merge: true }
    );
  }
  batch.set(eventRef, {
    type: eventType,
    userIDs: affectedUserIDs,
    receivedAt: serverTimestamp()
  });
  await batch.commit();

  response.status(200).send({ success: true });
});

function constantTimeEquals(lhs: string, rhs: string): boolean {
  const lhsBuffer = Buffer.from(lhs);
  const rhsBuffer = Buffer.from(rhs);
  return lhsBuffer.length === rhsBuffer.length && timingSafeEqual(lhsBuffer, rhsBuffer);
}

function appPlanFromProductID(productID: string): "monthly" | "annual" | "none" {
  if (!productID || productID === "none") {
    return "none";
  }

  const monthlyProductID = process.env.REVENUECAT_MONTHLY_PRODUCT_ID?.trim();
  const annualProductID = process.env.REVENUECAT_ANNUAL_PRODUCT_ID?.trim();

  if (monthlyProductID && productID === monthlyProductID) {
    return "monthly";
  }

  if (annualProductID && productID === annualProductID) {
    return "annual";
  }

  const normalized = productID.toLowerCase();
  if (normalized.includes("annual") || normalized.includes("year")) {
    return "annual";
  }

  if (normalized.includes("month")) {
    return "monthly";
  }

  return "none";
}
