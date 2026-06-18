const DEFAULT_PROVIDER = "stub";
const DEFAULT_VERTEX_LOCATION = "global";
const DEFAULT_VERTEX_MODEL = "gemini-3.1-flash-lite";
const DEFAULT_MAX_OUTPUT_TOKENS = 2048;

export type AIProviderMode = "stub" | "vertex";

export function getAIProviderMode(env: NodeJS.ProcessEnv = process.env): AIProviderMode {
  const rawProvider = env.AI_PROVIDER?.trim().toLowerCase();

  if (!rawProvider) {
    if (requiresExplicitAIProvider(env)) {
      throw new Error("AI_PROVIDER is required in managed Firebase runtimes. Set AI_PROVIDER=vertex.");
    }

    return DEFAULT_PROVIDER;
  }

  if (rawProvider === "vertex" || rawProvider === "vertexai" || rawProvider === "vertex-ai") {
    return "vertex";
  }

  if (rawProvider === "stub") {
    return "stub";
  }

  throw new Error(`Unsupported AI_PROVIDER "${rawProvider}". Expected "vertex" or "stub".`);
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

export function isAIStubFallbackEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const rawValue = env.AI_ENABLE_STUB_FALLBACK?.trim().toLowerCase();
  return rawValue === "true" || rawValue === "1" || rawValue === "yes";
}

export function assertAIProviderRuntimeConfiguration(env: NodeJS.ProcessEnv = process.env): void {
  if (!isManagedFirebaseRuntime(env)) {
    return;
  }

  const provider = getAIProviderMode(env);
  if (provider !== "vertex") {
    throw new Error("AI_PROVIDER must be vertex in managed Firebase runtimes.");
  }

  if (isAIStubFallbackEnabled(env)) {
    throw new Error("AI_ENABLE_STUB_FALLBACK must be false when AI_PROVIDER=vertex in managed Firebase runtimes.");
  }
}

export function isManagedFirebaseRuntime(env: NodeJS.ProcessEnv = process.env): boolean {
  if (env.CI === "true" || env.FUNCTIONS_EMULATOR === "true") {
    return false;
  }

  return Boolean(env.K_SERVICE || env.GAE_SERVICE || env.FUNCTION_TARGET || env.FUNCTION_SIGNATURE_TYPE);
}

function requiresExplicitAIProvider(env: NodeJS.ProcessEnv): boolean {
  return isManagedFirebaseRuntime(env);
}
