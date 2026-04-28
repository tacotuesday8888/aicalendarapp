import assert from "node:assert/strict";

type JsonObject = Record<string, unknown>;

async function runLiveFunctionSmokeTest() {
  const functionsBaseURL = requireEnv("FUNCTIONS_BASE_URL").replace(/\/+$/, "");
  const idToken = requireEnv("FIREBASE_ID_TOKEN");
  const userID = requireEnv("SMOKE_USER_ID");
  const appCheckToken = process.env.FIREBASE_APP_CHECK_TOKEN?.trim();
  const url = new URL("ai/run", `${functionsBaseURL}/`);
  const headers: Record<string, string> = {
    "Accept": "application/json",
    "Authorization": `Bearer ${idToken}`,
    "Content-Type": "application/json"
  };

  if (appCheckToken) {
    headers["X-Firebase-AppCheck"] = appCheckToken;
  } else {
    console.warn("FIREBASE_APP_CHECK_TOKEN is not set; this should only pass while APP_CHECK_MODE=monitor.");
  }

  const body = {
    workflow: "vibe_feedback",
    payload: {
      reflectionText: "I feel behind today, but I can start with one small task.",
      timezone: "America/New_York",
      recentContext: {
        userID
      }
    }
  };

  if (process.env.LIVE_SMOKE_DRY_RUN === "true") {
    console.log(
      JSON.stringify(
        {
          dryRun: true,
          method: "POST",
          url: url.toString(),
          hasAuthorization: Boolean(headers.Authorization),
          hasAppCheck: Boolean(headers["X-Firebase-AppCheck"]),
          bodyKeys: Object.keys(body)
        },
        null,
        2
      )
    );
    return;
  }

  const response = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(body)
  });
  const responseText = await response.text();
  const responseJSON = parseJSON(responseText);

  if (!response.ok) {
    throw new Error(`Live function smoke request failed with HTTP ${response.status}: ${responseText}`);
  }

  assert.ok(isJsonObject(responseJSON), "Expected a JSON object response.");
  assert.equal(responseJSON.workflow, "vibe_feedback", "Expected ai/run to return the vibe_feedback workflow.");
  assert.ok(isJsonObject(responseJSON.result), "Expected ai/run to return a result object.");
  const result = responseJSON.result;
  const feedback = result.feedback;
  assert.equal(typeof feedback, "string", "Expected vibe_feedback to return feedback.");
  assert.ok((feedback as string).length > 0, "Expected non-empty vibe feedback.");

  console.log(`Live function smoke test passed against ${url.toString()}.`);
}

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function parseJSON(rawValue: string): unknown {
  try {
    return JSON.parse(rawValue);
  } catch {
    return rawValue;
  }
}

function isJsonObject(value: unknown): value is JsonObject {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

runLiveFunctionSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
