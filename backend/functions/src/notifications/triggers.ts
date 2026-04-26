import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { logger } from "firebase-functions/v2";

import { sendPushNotificationToUser } from "./dispatch.js";

type StudySessionDoc = {
  status?: string;
  title?: string;
};

/**
 * Sends a push notification when a study session transitions to `completed`.
 * Fires only on the rising edge (status was not "completed" before).
 */
export const onStudySessionCompleted = onDocumentWritten(
  "users/{userID}/studySessions/{sessionID}",
  async (event) => {
    const userID = event.params.userID as string;
    const sessionID = event.params.sessionID as string;
    const before = event.data?.before.data() as StudySessionDoc | undefined;
    const after = event.data?.after.data() as StudySessionDoc | undefined;

    if (!after) {
      return;
    }

    const wasCompleted = before?.status === "completed";
    const isCompleted = after.status === "completed";

    if (wasCompleted || !isCompleted) {
      return;
    }

    try {
      await sendPushNotificationToUser(userID, {
        title: "Session complete",
        body: after.title ? `Nice work — \"${after.title}\" wrapped up.` : "Nice work — your session wrapped up.",
        category: "session_completed",
        data: { sessionID }
      });
    } catch (error) {
      logger.error("Failed to send session-completed notification.", {
        userID,
        sessionID,
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }
);
