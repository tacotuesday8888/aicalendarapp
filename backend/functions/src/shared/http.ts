import { getAuth } from "firebase-admin/auth";
import { logger } from "firebase-functions/v2";
import { HttpsError, onRequest, type HttpsOptions } from "firebase-functions/v2/https";
import type { Request, Response } from "express";
import { ZodError, type ZodType } from "zod";

import { verifyAppCheckRequest } from "./appCheck.js";

type AuthenticatedHandler<T> = (context: { authUID: string; data: T; request: Request }) => Promise<unknown>;

export function onAuthenticatedJsonRequest<T>(
  schema: ZodType<T>,
  handler: AuthenticatedHandler<T>,
  options: HttpsOptions = {}
) {
  return onRequest(options, async (request: Request, response: Response) => {
    if (request.method !== "POST") {
      response.status(405).json({ success: false, error: "Only POST requests are supported." });
      return;
    }

    try {
      await verifyAppCheckRequest(request, request.path || request.originalUrl || "authenticated-json-request");
      const authUID = await verifyBearerToken(request);
      const data = schema.parse(parseBody(request));
      const result = await handler({ authUID, data, request });
      response.status(200).json(result);
    } catch (error) {
      respondWithError(response, error);
    }
  });
}

function parseBody(request: Request): unknown {
  if (typeof request.body === "string") {
    return request.body.length ? JSON.parse(request.body) : {};
  }

  return request.body ?? {};
}

async function verifyBearerToken(request: Request): Promise<string> {
  const authorizationHeader = request.header("Authorization") ?? "";
  const token = authorizationHeader.startsWith("Bearer ") ? authorizationHeader.slice(7) : "";

  if (!token) {
    throw new HttpsError("unauthenticated", "Missing bearer token.");
  }

  const decodedToken = await getAuth().verifyIdToken(token);
  return decodedToken.uid;
}

function respondWithError(response: Response, error: unknown) {
  if (error instanceof ZodError) {
    response.status(400).json({
      success: false,
      error: "Invalid request payload.",
      issues: error.issues.map((issue) => ({
        path: issue.path.join("."),
        message: issue.message
      }))
    });
    return;
  }

  if (error instanceof SyntaxError) {
    response.status(400).json({
      success: false,
      error: "Invalid JSON request body."
    });
    return;
  }

  if (error instanceof HttpsError) {
    response.status(statusCode(error.code)).json({
      success: false,
      error: error.message
    });
    return;
  }

  logger.error("Authenticated JSON request failed", { error });
  response.status(500).json({
    success: false,
    error: "Internal server error."
  });
}

function statusCode(code: HttpsError["code"]): number {
  switch (code) {
    case "invalid-argument":
      return 400;
    case "unauthenticated":
      return 401;
    case "permission-denied":
      return 403;
    case "not-found":
      return 404;
    case "resource-exhausted":
      return 429;
    case "failed-precondition":
      return 412;
    default:
      return 500;
  }
}
