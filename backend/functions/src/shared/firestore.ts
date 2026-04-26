import { getApps, initializeApp } from "firebase-admin/app";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";

if (!getApps().length) {
  initializeApp();
}

export const db = getFirestore();
export const serverTimestamp = FieldValue.serverTimestamp;

export function userDoc(userID: string) {
  return db.collection("users").doc(userID);
}

export function userScopedCollection(userID: string, collection: string) {
  return userDoc(userID).collection(collection);
}

export function normalizeFirestoreValue(value: unknown): unknown {
  if (value instanceof Timestamp) {
    return value.toDate().toISOString();
  }

  if (Array.isArray(value)) {
    return value.map(normalizeFirestoreValue);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, childValue]) => [key, normalizeFirestoreValue(childValue)])
    );
  }

  return value;
}
