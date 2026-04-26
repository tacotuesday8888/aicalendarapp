const DEFAULT_PROVIDER = "stub";
const DEFAULT_VERTEX_LOCATION = "us-central1";
const DEFAULT_VERTEX_MODEL = "gemini-2.5-flash-lite";
const DEFAULT_MAX_OUTPUT_TOKENS = 2048;

export type AIProviderMode = "stub" | "vertex";

export function getAIProviderMode(): AIProviderMode {
  const rawProvider = (process.env.AI_PROVIDER ?? DEFAULT_PROVIDER).trim().toLowerCase();

  if (rawProvider === "vertex" || rawProvider === "vertexai" || rawProvider === "vertex-ai") {
    return "vertex";
  }

  return "stub";
}

export function getAIModelName(): string {
  return process.env.AI_MODEL?.trim() || DEFAULT_VERTEX_MODEL;
}

export function getAIVertexLocation(): string {
  return process.env.AI_VERTEX_LOCATION?.trim() || process.env.GCLOUD_LOCATION?.trim() || DEFAULT_VERTEX_LOCATION;
}

export function getAIMaxOutputTokens(): number {
  const rawValue = process.env.AI_MAX_OUTPUT_TOKENS ?? process.env.MAX_TOKENS;
  const parsed = rawValue ? Number.parseInt(rawValue, 10) : DEFAULT_MAX_OUTPUT_TOKENS;
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_MAX_OUTPUT_TOKENS;
}
