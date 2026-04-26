import { HttpsError } from "firebase-functions/v2/https";

export function requireMatchingUser(authUID: string | undefined, requestedUserID: string): string {
  if (!authUID) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  if (authUID != requestedUserID) {
    throw new HttpsError("permission-denied", "User mismatch.");
  }

  return authUID;
}
