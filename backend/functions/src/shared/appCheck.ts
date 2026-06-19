import { getAppCheck } from "firebase-admin/app-check";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";
import type { Request } from "express";

type AppCheckMode = "off" | "monitor" | "enforce";

export async function verifyAppCheckRequest(request: Request, routeName: string) {
  let mode: AppCheckMode;
  try {
    mode = resolveAppCheckMode();
  } catch (error) {
    logger.error("App Check mode is misconfigured.", {
      routeName,
      error: error instanceof Error ? error.message : String(error)
    });
    throw new HttpsError("failed-precondition", "App Check is misconfigured.");
  }

  if (mode === "off") {
    return;
  }

  const appCheckToken = request.header("X-Firebase-AppCheck") ?? "";
  if (!appCheckToken) {
    handleAppCheckFailure(mode, routeName, "Missing App Check token.");
    return;
  }

  try {
    await getAppCheck().verifyToken(appCheckToken);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid App Check token.";
    handleAppCheckFailure(mode, routeName, message);
  }
}

export function resolveAppCheckMode(env: NodeJS.ProcessEnv = process.env): AppCheckMode {
  const explicitMode = env.APP_CHECK_MODE?.trim().toLowerCase();
  if (explicitMode === "off" || explicitMode === "disabled" || explicitMode === "false") {
    return "off";
  }
  if (explicitMode === "enforce" || explicitMode === "required" || explicitMode === "true") {
    return "enforce";
  }
  if (explicitMode === "monitor" || explicitMode === "warn") {
    return "monitor";
  }
  if (explicitMode) {
    throw new Error(`Unsupported APP_CHECK_MODE "${explicitMode}". Expected "off", "monitor", or "enforce".`);
  }

  const legacyEnforcement = env.APP_CHECK_ENFORCEMENT?.trim().toLowerCase();
  if (legacyEnforcement === "true" || legacyEnforcement === "1" || legacyEnforcement === "enforce") {
    return "enforce";
  }
  if (legacyEnforcement === "false" || legacyEnforcement === "0" || legacyEnforcement === "off") {
    return "off";
  }

  return "monitor";
}

function handleAppCheckFailure(mode: AppCheckMode, routeName: string, reason: string) {
  if (mode === "enforce") {
    throw new HttpsError("unauthenticated", "Valid App Check is required.");
  }

  logger.warn("App Check verification failed in monitor mode", {
    routeName,
    reason
  });
}
