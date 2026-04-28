import { HttpsError, onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { timingSafeEqual } from "node:crypto";

import { db, serverTimestamp, userScopedCollection } from "../shared/firestore.js";
import { revenueCatSyncOptions, revenueCatWebhookOptions } from "../shared/functionOptions.js";
import { userJobRequestSchema } from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";

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
  source: "revenuecat_rest_api" | "revenuecat_webhook_fallback" | "revenuecat_transfer";
};

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

function deriveSnapshotFromEvent(event: RevenueCatWebhookEvent): SubscriptionSnapshot {
  const entitlementIDs = Array.isArray(event.entitlement_ids)
    ? event.entitlement_ids.filter((value): value is string => typeof value === "string" && value.length > 0)
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

function expirationTimestampForEntitlement(entitlement: RevenueCatSubscriberEntitlement): number {
  return parseIsoTimestamp(entitlement.expires_date) ?? Number.MAX_SAFE_INTEGER;
}

function deriveSnapshotFromSubscriberResponse(response: RevenueCatSubscriberResponse): SubscriptionSnapshot {
  const entitlements = response.subscriber?.entitlements ?? {};
  const activeEntitlements = Object.entries(entitlements).filter(([, entitlement]) => {
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
  await userScopedCollection(userID, "subscriptions").doc("current").set({
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
  }, { merge: true });
}

export const syncRevenueCatSubscription = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const secretApiKey = process.env.REVENUECAT_SECRET_API_KEY?.trim();

  if (!secretApiKey) {
    throw new HttpsError("failed-precondition", "RevenueCat subscriber sync is not configured.");
  }

  const snapshot = await fetchRevenueCatSubscriberSnapshot(userID, secretApiKey);
  const syncEventID = `subscriber-sync-${userID}-${Date.now()}`;
  await persistSubscriptionSnapshot(
    userID,
    snapshot,
    {
      id: syncEventID,
      type: "SUBSCRIBER_SYNC"
    },
    syncEventID
  );

  return { success: true };
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

  const primaryUserIDs = uniqueUserIDs([
    event.app_user_id,
    event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : [])
  ]);
  const transferredFromUserIDs = uniqueUserIDs(Array.isArray(event.transferred_from) ? event.transferred_from : []);
  const transferredToUserIDs = uniqueUserIDs(Array.isArray(event.transferred_to) ? event.transferred_to : []);
  const affectedUserIDs = uniqueUserIDs([
    ...primaryUserIDs,
    ...transferredFromUserIDs,
    ...transferredToUserIDs
  ]);

  if (affectedUserIDs.length === 0) {
    response.status(400).send({ success: false, reason: "Missing RevenueCat user identifiers." });
    return;
  }

  const secretApiKey = process.env.REVENUECAT_SECRET_API_KEY?.trim();
  const snapshotCache = new Map<string, SubscriptionSnapshot>();

  const snapshotFor = async (userID: string, fallback: SubscriptionSnapshot): Promise<SubscriptionSnapshot> => {
    const cached = snapshotCache.get(userID);
    if (cached) {
      return cached;
    }

    let snapshot = fallback;
    if (secretApiKey) {
      try {
        snapshot = await fetchRevenueCatSubscriberSnapshot(userID, secretApiKey);
      } catch (error) {
        logger.warn("RevenueCat subscriber lookup failed; falling back to webhook event payload.", {
          eventID,
          eventType,
          userID,
          error: error instanceof Error ? error.message : String(error)
        });
      }
    }

    snapshotCache.set(userID, snapshot);
    return snapshot;
  };

  const writes: Promise<void>[] = [];
  for (const userID of primaryUserIDs) {
    writes.push(snapshotFor(userID, deriveSnapshotFromEvent(event)).then((snapshot) => persistSubscriptionSnapshot(userID, snapshot, event, eventID)));
  }

  for (const userID of transferredToUserIDs) {
    writes.push(snapshotFor(userID, deriveTransferDestinationSnapshot(event)).then((snapshot) => persistSubscriptionSnapshot(userID, snapshot, event, eventID)));
  }

  for (const userID of transferredFromUserIDs) {
    writes.push(snapshotFor(userID, deriveTransferSourceSnapshot()).then((snapshot) => persistSubscriptionSnapshot(userID, snapshot, event, eventID)));
  }

  await Promise.all(writes);

  await eventRef.set({
    type: eventType,
    userIDs: affectedUserIDs,
    receivedAt: serverTimestamp()
  });

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
