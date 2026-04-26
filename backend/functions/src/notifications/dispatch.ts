import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";

import { userDoc } from "../shared/firestore.js";

export async function queueNotificationAudit(userID: string, category: string) {
  return sendPushNotificationToUser(userID, {
    title: "AI Efficiency update",
    body: "There is a new planning update waiting in your workspace.",
    category
  });
}

type PushPayload = {
  title: string;
  body: string;
  category: string;
  data?: Record<string, string>;
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

  logger.info("Notification delivered.", {
    userID,
    category: payload.category
  });

  return { delivered: true };
}
