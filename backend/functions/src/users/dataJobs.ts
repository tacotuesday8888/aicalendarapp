import { getAuth } from "firebase-admin/auth";
import { FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { userJobRequestSchema } from "../shared/contracts.js";
import { requireMatchingUser } from "../shared/context.js";
import { db, normalizeFirestoreValue, serverTimestamp, userDoc, userScopedCollection } from "../shared/firestore.js";
import { onAuthenticatedJsonRequest } from "../shared/http.js";

const exportCollections = [
  "onboarding",
  "goals",
  "goalPlans",
  "plannerBlocks",
  "courses",
  "assignments",
  "habits",
  "studySessions",
  "checkIns",
  "vibeChecks",
  "reminderRules",
  "assistantThreads",
  "imports",
  "subscriptions",
  "aiDrafts",
  "aiUsage",
  "aiUsageDaily",
  "aiUsageLogs",
  "assistantDraftArtifacts"
];
const revenueCatWebhookEventsCollection = "_revenuecatWebhookEvents";

export const exportUserData = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const profileSnapshot = await userDoc(userID).get();
  const [exportedCollections, revenueCatWebhookEvents] = await Promise.all([
    Promise.all(
      exportCollections.map(async (collection) => {
        const records = await exportCollection(userID, collection);
        return [collection, records] as const;
      })
    ),
    exportRevenueCatWebhookEvents(userID)
  ]);

  return {
    userID,
    requestedAt: new Date().toISOString(),
    profile: normalizeFirestoreValue(profileSnapshot.data() ?? {}),
    collections: Object.fromEntries(exportedCollections),
    systemCollections: {
      revenueCatWebhookEvents
    }
  };
});

export const deleteUserAccount = onAuthenticatedJsonRequest(userJobRequestSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  const deletedStoragePrefix = await deleteUserStorageFiles(userID);
  const [deletedCollections, redactedRevenueCatWebhookEvents] = await Promise.all([
    Promise.all(
      exportCollections.map(async (collection) => {
        const deletedCount = await deleteCollection(userID, collection);
        return [collection, deletedCount] as const;
      })
    ),
    redactUserIDFromRevenueCatWebhookEvents(userID)
  ]);

  await userDoc(userID).delete();
  await deleteAuthUserIfPresent(userID);

  return {
    success: true,
    userID,
    deletedCollections: Object.fromEntries(deletedCollections),
    redactedSystemCollections: {
      revenueCatWebhookEvents: redactedRevenueCatWebhookEvents
    },
    deletedStoragePrefix
  };
});

async function exportCollection(userID: string, collection: string) {
  const snapshot = await userScopedCollection(userID, collection).get();
  return snapshot.docs.map((document) => {
    const normalized = normalizeFirestoreValue(document.data());

    if (normalized && typeof normalized === "object" && !Array.isArray(normalized)) {
      return {
        id: document.id,
        ...(normalized as Record<string, unknown>)
      };
    }

    return {
      id: document.id,
      value: normalized
    };
  });
}

async function deleteUserStorageFiles(userID: string): Promise<string> {
  const prefix = `users/${userID}/`;
  await getStorage().bucket().deleteFiles({ prefix, force: true });
  return prefix;
}

async function deleteCollection(userID: string, collection: string): Promise<number> {
  const snapshot = await userScopedCollection(userID, collection).get();
  const chunks = chunk(snapshot.docs, 400);

  for (const documents of chunks) {
    const batch = db.batch();
    documents.forEach((document) => batch.delete(document.ref));
    await batch.commit();
  }

  return snapshot.size;
}

async function exportRevenueCatWebhookEvents(userID: string) {
  const snapshot = await db.collection(revenueCatWebhookEventsCollection)
    .where("userIDs", "array-contains", userID)
    .get();

  return snapshot.docs.map((document) => {
    const normalized = normalizeFirestoreValue(document.data());

    if (normalized && typeof normalized === "object" && !Array.isArray(normalized)) {
      return {
        id: document.id,
        ...(normalized as Record<string, unknown>),
        userIDs: [userID]
      };
    }

    return {
      id: document.id,
      userIDs: [userID],
      value: normalized
    };
  });
}

async function redactUserIDFromRevenueCatWebhookEvents(userID: string): Promise<number> {
  const snapshot = await db.collection(revenueCatWebhookEventsCollection)
    .where("userIDs", "array-contains", userID)
    .get();
  const chunks = chunk(snapshot.docs, 400);

  for (const documents of chunks) {
    const batch = db.batch();
    documents.forEach((document) => batch.update(document.ref, {
      userIDs: FieldValue.arrayRemove(userID),
      redactedAt: serverTimestamp()
    }));
    await batch.commit();
  }

  return snapshot.size;
}

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];

  for (let index = 0; index < items.length; index += size) {
    chunks.push(items.slice(index, index + size));
  }

  return chunks;
}

async function deleteAuthUserIfPresent(userID: string): Promise<void> {
  try {
    await getAuth().deleteUser(userID);
  } catch (error) {
    if (firebaseAuthErrorCode(error) === "auth/user-not-found") {
      return;
    }
    throw error;
  }
}

function firebaseAuthErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") {
    return null;
  }

  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : null;
}
