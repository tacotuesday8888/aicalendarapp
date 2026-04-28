import { logger } from "firebase-functions/v2";
import type { Request } from "express";

export function logLegacyAIEndpointUse(legacyEndpoint: string, callerUID: string, request: Request): void {
  logger.warn("Legacy AI endpoint called.", {
    "caller-uid": callerUID,
    "legacy-endpoint": legacyEndpoint,
    "client-version": clientVersion(request)
  });
}

function clientVersion(request: Request): string | null {
  return request.header("X-Client-Version") ?? request.header("X-App-Version") ?? null;
}
