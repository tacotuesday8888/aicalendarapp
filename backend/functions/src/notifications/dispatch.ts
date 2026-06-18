import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";
import { FieldValue } from "firebase-admin/firestore";

import { db, serverTimestamp, userDoc } from "../shared/firestore.js";

type PushPayload = {
  title: string;
  body: string;
  category: string;
  data?: Record<string, string>;
};

const invalidPushTokenErrorCodes = new Set([
  "messaging/invalid-argument",
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered"
]);

type FirebaseMessagingErrorLike = {
  code?: unknown;
  errorInfo?: {
    code?: unknown;
  };
};

export async function sendPushNotificationToUser(userID: string, payload: PushPayload) {
  const snapshot = await userDoc(userID).get();
  const pushToken = snapshot.data()?.pushToken;

  if (typeof pushToken !== "string" || !pushToken.length) {
    logger.info("Skipping push fanout because no token is available.", {
      userID,
      category: payload.category
    });
    return { delivered: false };
  }

  try {
    await getMessaging().send({
      token: pushToken,
      notification: {
        title: payload.title,
        body: payload.body
      },
      data: {
        category: payload.category,
        ...(payload.data ?? {})
      }
    });
  } catch (error) {
    if (isInvalidPushTokenError(error)) {
      const staleTokenCleared = await clearPushTokenIfStillCurrent(userID, pushToken);
      logger.warn("Removed stale push token after FCM send failure.", {
        userID,
        category: payload.category,
        staleTokenCleared,
        errorCode: firebaseMessagingErrorCode(error)
      });
      return { delivered: false, staleTokenCleared };
    }

    throw error;
  }

  logger.info("Notification delivered.", {
    userID,
    category: payload.category
  });

  return { delivered: true };
}

export function isInvalidPushTokenError(error: unknown): boolean {
  const code = firebaseMessagingErrorCode(error);
  return code != null && invalidPushTokenErrorCodes.has(code);
}

export function firebaseMessagingErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") {
    return null;
  }

  const candidate = error as FirebaseMessagingErrorLike;
  if (typeof candidate.code === "string") {
    return candidate.code;
  }
  if (typeof candidate.errorInfo?.code === "string") {
    return candidate.errorInfo.code;
  }
  return null;
}

export async function clearPushTokenIfStillCurrent(userID: string, pushToken: string): Promise<boolean> {
  let staleTokenCleared = false;
  const ref = userDoc(userID);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (snapshot.get("pushToken") !== pushToken) {
      return;
    }

    transaction.update(ref, {
      pushToken: FieldValue.delete(),
      pushTokenClearedAt: serverTimestamp()
    });
    staleTokenCleared = true;
  });

  return staleTokenCleared;
}
