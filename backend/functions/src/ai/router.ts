import { getAuth } from "firebase-admin/auth";
import { logger } from "firebase-functions/v2";
import { HttpsError, onRequest } from "firebase-functions/v2/https";
import type { Request, Response } from "express";

import { verifyAppCheckRequest } from "../shared/appCheck.js";
import { aiFunctionOptions } from "../shared/functionOptions.js";
import { loadAssistantWorkflowContext, loadGoalPlanWorkflowContext } from "./context.js";
import {
  storeAssistantChatReviewState,
  storeGoalPlanReviewDraft,
  storeReviewDraft,
  storeSyllabusImportReviewJob
} from "./drafts.js";
import {
  assistantChatFlow,
  goalPlanGenerationFlow,
  syllabusImportFlow,
  vibeFeedbackFlow
} from "./workflows.js";
import { aiRunRequestSchema, type AIRunRequest, type AIWorkflow } from "./schemas.js";
import { authorizeAndReserveAIUsage, logAIUsage } from "./usage.js";

type AIRunSuccess = {
  workflow: AIWorkflow;
  result: unknown;
  draftID: string | null;
  degraded?: true;
};

type AIErrorCode = "invalid_payload" | "unauthorized" | "rate_limited" | "workflow_failed" | "internal_error";

export const ai = onRequest(aiFunctionOptions, async (request: Request, response: Response) => {
  if (!isAIRunPath(request)) {
    response.status(404).json({
      error: {
        code: "workflow_failed",
        message: "Unknown AI route."
      }
    });
    return;
  }

  if (request.method !== "POST") {
    response.status(405).json({
      error: {
        code: "workflow_failed",
        message: "Only POST requests are supported."
      }
    });
    return;
  }

  let parsedRequest: AIRunRequest | null = null;
  let authUID: string | null = null;

  try {
    await verifyAppCheckRequest(request, request.path || "ai");
    authUID = await verifyBearerToken(request);

    const parseResult = aiRunRequestSchema.safeParse(parseBody(request));
    if (!parseResult.success) {
      response.status(400).json({
        error: {
          code: "invalid_payload",
          message: "Invalid request."
        }
      });
      return;
    }

    parsedRequest = parseResult.data;
    await authorizeAndReserveAIUsage(authUID, parsedRequest.workflow);

    if (parsedRequest.workflow === "assistant_chat" && wantsStreamingResponse(request)) {
      await streamAssistantChat(authUID, parsedRequest, response);
      return;
    }

    const result = await runAIWorkflow(authUID, parsedRequest);
    await logAIUsage(authUID, parsedRequest.workflow, "success");
    response.status(200).json(result);
  } catch (error) {
    const workflow = parsedRequest?.workflow;
    if (authUID && workflow) {
      await logAIUsage(authUID, workflow, "error", { errorCode: mapError(error).code }).catch(() => undefined);
    }

    respondWithAIError(response, error);
  }
});

async function runAIWorkflow(userID: string, request: AIRunRequest): Promise<AIRunSuccess> {
  switch (request.workflow) {
    case "assistant_chat": {
      const context = await loadAssistantWorkflowContext(userID, request.payload);
      const result = await assistantChatFlow({ userID, payload: request.payload, context });
      const draftID = await storeReviewDraft(userID, request.workflow, result);
      await storeAssistantChatReviewState(userID, request.payload, result, draftID);
      return withDegradedFlag({ workflow: request.workflow, result, draftID }, result);
    }
    case "goal_plan_generation": {
      const context = await loadGoalPlanWorkflowContext(userID, request.payload);
      const result = await goalPlanGenerationFlow({ userID, payload: request.payload, context });
      const draftID = await storeReviewDraft(userID, request.workflow, result);
      if (draftID) {
        await storeGoalPlanReviewDraft(userID, request.payload, result, draftID);
      }
      return withDegradedFlag({ workflow: request.workflow, result, draftID }, result);
    }
    case "vibe_feedback": {
      const result = await vibeFeedbackFlow({ userID, payload: request.payload });
      return withDegradedFlag({ workflow: request.workflow, result, draftID: null }, result);
    }
    case "syllabus_import": {
      const result = await syllabusImportFlow({ userID, payload: request.payload });
      const draftID = await storeSyllabusImportReviewJob(userID, request.payload, result);
      return withDegradedFlag({ workflow: request.workflow, result, draftID }, result);
    }
  }
}

async function streamAssistantChat(userID: string, request: Extract<AIRunRequest, { workflow: "assistant_chat" }>, response: Response) {
  response.status(200);
  response.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  response.setHeader("Cache-Control", "no-cache, no-transform");
  response.setHeader("Connection", "keep-alive");

  try {
    const context = await loadAssistantWorkflowContext(userID, request.payload);
    const streamResponse = assistantChatFlow.stream({ userID, payload: request.payload, context });

    for await (const chunk of streamResponse.stream) {
      writeSSE(response, "chunk", { text: chunk });
    }

    const result = await streamResponse.output;
    const draftID = await storeReviewDraft(userID, request.workflow, result);
    await storeAssistantChatReviewState(userID, request.payload, result, draftID);
    await logAIUsage(userID, request.workflow, "success", { streamed: true });
    writeSSE(response, "final", withDegradedFlag({ workflow: request.workflow, result, draftID }, result));
    response.end();
  } catch (error) {
    await logAIUsage(userID, request.workflow, "error", { streamed: true, errorCode: mapError(error).code }).catch(
      () => undefined
    );
    writeSSE(response, "error", {
      error: {
        code: mapError(error).code,
        message: "AI request failed."
      }
    });
    response.end();
  }
}

function isAIRunPath(request: Request): boolean {
  return request.path === "/" || request.path === "/run";
}

function wantsStreamingResponse(request: Request): boolean {
  const accept = request.header("Accept") ?? "";
  return accept.includes("text/event-stream") || request.query.stream === "true";
}

function withDegradedFlag(response: AIRunSuccess, result: unknown): AIRunSuccess {
  return isDegradedResult(result) ? { ...response, degraded: true } : response;
}

function isDegradedResult(result: unknown): boolean {
  return Boolean(result && typeof result === "object" && "degraded" in result && result.degraded === true);
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

function respondWithAIError(response: Response, error: unknown) {
  if (response.headersSent) {
    response.end();
    return;
  }

  const mapped = mapError(error);
  const logPayload = {
    code: mapped.code,
    status: mapped.status,
    errorName: errorName(error),
    httpsCode: httpsErrorCode(error),
    stack: stackFrames(error)
  };
  if (mapped.status >= 500) {
    logger.error("AI workflow failed", logPayload);
  } else {
    logger.warn("AI request rejected", logPayload);
  }
  response.status(mapped.status).json({
    error: {
      code: mapped.code,
      message: mapped.message
    }
  });
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : typeof error;
}

function httpsErrorCode(error: unknown): string | null {
  return error instanceof HttpsError ? error.code : null;
}

function stackFrames(error: unknown): string | null {
  if (!(error instanceof Error) || !error.stack) {
    return null;
  }

  const frames = error.stack.split("\n").slice(1, 8).map((line) => line.trim()).filter(Boolean);
  return frames.length ? frames.join("\n") : null;
}

function mapError(error: unknown): { code: AIErrorCode; status: number; message: string } {
  if (error instanceof HttpsError) {
    switch (error.code) {
      case "unauthenticated":
        return { code: "unauthorized", status: 401, message: "Authentication is required." };
      case "resource-exhausted":
        return { code: "rate_limited", status: 429, message: error.message };
      case "permission-denied":
        return { code: "unauthorized", status: 403, message: error.message };
      case "invalid-argument":
        return { code: "invalid_payload", status: 400, message: "Invalid request." };
      default:
        return { code: "workflow_failed", status: 500, message: "AI request failed." };
    }
  }

  if (error instanceof SyntaxError) {
    return { code: "invalid_payload", status: 400, message: "Invalid request." };
  }

  return { code: "internal_error", status: 500, message: "AI request failed." };
}

function writeSSE(response: Response, event: string, data: unknown) {
  response.write(`event: ${event}\n`);
  response.write(`data: ${JSON.stringify(data)}\n\n`);
}
