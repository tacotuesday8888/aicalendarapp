import assert from "node:assert/strict";

type JsonObject = Record<string, unknown>;
type SmokeRequest = {
  name: string;
  path: string;
  body: JsonObject;
  assertResponse: (responseJSON: unknown) => void;
};

async function runLiveFunctionSmokeTest() {
  const dryRun = process.env.LIVE_SMOKE_DRY_RUN === "true";
  const functionsBaseURL = requireEnv("FUNCTIONS_BASE_URL").replace(/\/+$/, "");
  const idToken = dryRun ? process.env.FIREBASE_ID_TOKEN?.trim() ?? "" : requireEnv("FIREBASE_ID_TOKEN");
  const userID = dryRun ? process.env.SMOKE_USER_ID?.trim() || "dry-run-user" : requireEnv("SMOKE_USER_ID");
  const appCheckToken = process.env.FIREBASE_APP_CHECK_TOKEN?.trim();
  const headers: Record<string, string> = {
    "Accept": "application/json",
    "Content-Type": "application/json"
  };

  if (idToken) {
    headers.Authorization = `Bearer ${idToken}`;
  }

  if (appCheckToken) {
    headers["X-Firebase-AppCheck"] = appCheckToken;
  } else if (!dryRun) {
    console.warn("FIREBASE_APP_CHECK_TOKEN is not set; this should only pass while APP_CHECK_MODE=monitor.");
  }

  const requests = liveSmokeRequests(userID);

  if (dryRun) {
    console.log(
      JSON.stringify(
        {
          dryRun: true,
          hasAuthorization: Boolean(headers.Authorization),
          hasAppCheck: Boolean(headers["X-Firebase-AppCheck"]),
          requests: requests.map((request) => ({
            name: request.name,
            method: "POST",
            url: urlFor(functionsBaseURL, request.path).toString(),
            bodyKeys: Object.keys(request.body)
          }))
        },
        null,
        2
      )
    );
    return;
  }

  for (const request of requests) {
    const url = urlFor(functionsBaseURL, request.path);
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(request.body)
    });
    const responseText = await response.text();
    const responseJSON = parseJSON(responseText);

    if (!response.ok) {
      throw new Error(`${request.name} failed with HTTP ${response.status}: ${responseText}`);
    }

    request.assertResponse(responseJSON);
    console.log(`${request.name} passed against ${url.toString()}.`);
  }

  console.log(`Live function smoke matrix passed for ${requests.length} request(s).`);
}

function liveSmokeRequests(userID: string): SmokeRequest[] {
  const requests: SmokeRequest[] = [
    {
      name: "ai/run vibe_feedback",
      path: "ai/run",
      body: {
        workflow: "vibe_feedback",
        payload: {
          reflectionText: process.env.SMOKE_REFLECTION_TEXT?.trim() || "I feel behind today, but I can start with one small task.",
          timezone: "America/New_York",
          recentContext: {
            userID
          }
        }
      },
      assertResponse: assertVibeFeedbackResponse
    },
    {
      name: "syncRevenueCatSubscription",
      path: "syncRevenueCatSubscription",
      body: {
        userID
      },
      assertResponse: assertSubscriptionSyncResponse
    },
    {
      name: "exportUserData",
      path: "exportUserData",
      body: {
        userID
      },
      assertResponse: (responseJSON) => assertExportUserDataResponse(responseJSON, userID)
    }
  ];

  if (process.env.LIVE_SMOKE_INCLUDE_DELETE_ACCOUNT === "true") {
    const confirmation = process.env.LIVE_SMOKE_CONFIRM_DELETE_ACCOUNT?.trim();
    assert.equal(
      confirmation,
      `DELETE ${userID}`,
      "LIVE_SMOKE_CONFIRM_DELETE_ACCOUNT must equal `DELETE ${SMOKE_USER_ID}` before deleteUserAccount is included."
    );
    requests.push({
      name: "deleteUserAccount",
      path: "deleteUserAccount",
      body: {
        userID
      },
      assertResponse: (responseJSON) => assertDeleteUserAccountResponse(responseJSON, userID)
    });
  }

  return requests;
}

function assertVibeFeedbackResponse(responseJSON: unknown) {
  assert.ok(isJsonObject(responseJSON), "Expected a JSON object response.");
  assert.equal(responseJSON.workflow, "vibe_feedback", "Expected ai/run to return the vibe_feedback workflow.");
  assert.ok(isJsonObject(responseJSON.result), "Expected ai/run to return a result object.");
  const result = responseJSON.result;
  const feedback = result.feedback;
  assert.equal(typeof feedback, "string", "Expected vibe_feedback to return feedback.");
  assert.ok((feedback as string).length > 0, "Expected non-empty vibe feedback.");
}

function assertSubscriptionSyncResponse(responseJSON: unknown) {
  assert.ok(isJsonObject(responseJSON), "Expected subscription sync to return a JSON object.");
  assert.equal(responseJSON.success, true, "Expected subscription sync success=true.");
  assert.ok(isJsonObject(responseJSON.subscription), "Expected subscription sync to return a subscription object.");

  const subscription = responseJSON.subscription;
  assert.ok(
    subscription.entitlement === "active" || subscription.entitlement === "inactive",
    "Expected subscription entitlement to be active or inactive."
  );
  assert.ok(
    subscription.activePlan === "monthly" || subscription.activePlan === "annual" || subscription.activePlan === "none",
    "Expected subscription activePlan to be monthly, annual, or none."
  );
  assert.equal(typeof subscription.trialEligible, "boolean", "Expected subscription trialEligible boolean.");
  assert.equal(typeof subscription.lastSyncedAt, "string", "Expected subscription lastSyncedAt string.");
}

function assertExportUserDataResponse(responseJSON: unknown, userID: string) {
  assert.ok(isJsonObject(responseJSON), "Expected exportUserData to return a JSON object.");
  assert.equal(responseJSON.userID, userID, "Expected exportUserData to return the requested userID.");
  assert.equal(typeof responseJSON.requestedAt, "string", "Expected exportUserData requestedAt string.");
  assert.ok(isJsonObject(responseJSON.profile), "Expected exportUserData profile object.");
  assert.ok(isJsonObject(responseJSON.collections), "Expected exportUserData collections object.");
}

function assertDeleteUserAccountResponse(responseJSON: unknown, userID: string) {
  assert.ok(isJsonObject(responseJSON), "Expected deleteUserAccount to return a JSON object.");
  assert.equal(responseJSON.success, true, "Expected deleteUserAccount success=true.");
  assert.equal(responseJSON.userID, userID, "Expected deleteUserAccount to return the deleted userID.");
  assert.ok(isJsonObject(responseJSON.deletedCollections), "Expected deleteUserAccount deletedCollections object.");
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

function urlFor(functionsBaseURL: string, path: string): URL {
  return new URL(path, `${functionsBaseURL}/`);
}

runLiveFunctionSmokeTest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
