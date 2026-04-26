import { z } from "zod";

import { onAuthenticatedJsonRequest } from "../shared/http.js";
import { requireMatchingUser } from "../shared/context.js";
import { sendPushNotificationToUser } from "./dispatch.js";

const sendTestPushSchema = z.object({
  userID: z.string().min(1),
  title: z.string().min(1).max(120).optional(),
  body: z.string().min(1).max(500).optional()
});

export const sendTestPush = onAuthenticatedJsonRequest(sendTestPushSchema, async ({ authUID, data }) => {
  const userID = requireMatchingUser(authUID, data.userID);
  return sendPushNotificationToUser(userID, {
    title: data.title ?? "Test notification",
    body: data.body ?? "This is a test push from your AI Efficiency backend.",
    category: "test_push"
  });
});
