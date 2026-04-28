import { logger } from "firebase-functions/v2";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldPath, Timestamp, type CollectionReference, type DocumentData, type Query } from "firebase-admin/firestore";

import { db } from "../shared/firestore.js";

export const AI_USAGE_DAILY_RETENTION_DAYS = 90;
export const AI_USAGE_EVENT_RETENTION_DAYS = 180;

const USER_PAGE_LIMIT = 100;
const DELETE_BATCH_LIMIT = 250;
const MAX_DELETES_PER_COLLECTION_PER_RUN = 1_000;

type CleanupResult = {
  collection: "aiUsage" | "aiUsageDaily";
  deleted: number;
  scannedUsers: number;
  cutoff: string;
};

export const cleanupAIUsageDocs = onSchedule(
  {
    schedule: "every day 03:30",
    timeZone: "Etc/UTC",
    timeoutSeconds: 540,
    memory: "256MiB",
    minInstances: 0,
    maxInstances: 1
  },
  async () => {
    const [dailyResult, eventResult] = await Promise.all([
      deleteOldUserScopedDocs("aiUsageDaily", cutoffDate(AI_USAGE_DAILY_RETENTION_DAYS)),
      deleteOldUserScopedDocs("aiUsage", cutoffDate(AI_USAGE_EVENT_RETENTION_DAYS))
    ]);

    logger.info("AI usage cleanup finished.", {
      results: [dailyResult, eventResult]
    });
  }
);

async function deleteOldUserScopedDocs(
  collection: CleanupResult["collection"],
  cutoff: Date
): Promise<CleanupResult> {
  let deleted = 0;
  let scannedUsers = 0;
  let lastUserID: string | null = null;

  while (deleted < MAX_DELETES_PER_COLLECTION_PER_RUN) {
    let usersQuery = db.collection("users")
      .orderBy(FieldPath.documentId())
      .limit(USER_PAGE_LIMIT) as Query<DocumentData>;

    if (lastUserID) {
      usersQuery = usersQuery.startAfter(lastUserID);
    }

    const usersSnapshot = await usersQuery.get();
    if (usersSnapshot.empty) {
      break;
    }

    for (const userSnapshot of usersSnapshot.docs) {
      scannedUsers += 1;
      const remainingDeletes = MAX_DELETES_PER_COLLECTION_PER_RUN - deleted;
      deleted += await deleteOldDocsFromCollection(
        userSnapshot.ref.collection(collection),
        cutoff,
        Math.min(DELETE_BATCH_LIMIT, remainingDeletes)
      );

      if (deleted >= MAX_DELETES_PER_COLLECTION_PER_RUN) {
        break;
      }
    }

    lastUserID = usersSnapshot.docs[usersSnapshot.docs.length - 1]?.id ?? null;
    if (!lastUserID || usersSnapshot.size < USER_PAGE_LIMIT) {
      break;
    }
  }

  return {
    collection,
    deleted,
    scannedUsers,
    cutoff: cutoff.toISOString()
  };
}

async function deleteOldDocsFromCollection(
  collection: CollectionReference,
  cutoff: Date,
  limit: number
): Promise<number> {
  if (limit <= 0) {
    return 0;
  }

  const snapshot = await collection
    .where("createdAt", "<", Timestamp.fromDate(cutoff))
    .orderBy("createdAt")
    .limit(limit)
    .get();

  if (snapshot.empty) {
    return 0;
  }

  const batch = db.batch();
  for (const doc of snapshot.docs) {
    batch.delete(doc.ref);
  }
  await batch.commit();
  return snapshot.size;
}

function cutoffDate(retentionDays: number): Date {
  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - retentionDays);
  return cutoff;
}
