# Backend Function Contracts

These authenticated JSON HTTP and webhook endpoints are the server boundary for privileged logic.

The iOS app sends `POST` JSON requests to the Firebase Functions base URL in `API_BASE_URL`. Authenticated endpoints receive a `userID` in the JSON body and validate it against the verified Firebase token on the server. App-originated requests also include Firebase App Check when Firebase is configured.

## Authenticated JSON endpoints

- `ai/run`
  - Input: `workflow`, `payload`
  - Output: `{ workflow, result, draftID }`
  - Ownership: server verifies Firebase Auth, loads Firestore context, runs the selected Genkit workflow, validates structured output, logs usage, and stores review drafts where needed
  - Supported workflows: `assistant_chat`, `goal_plan_generation`, `vibe_feedback`, `syllabus_import`
  - Streaming: `assistant_chat` can return Server-Sent Events when the request accepts `text/event-stream`; other workflows return normal JSON

- `assistantRespond`
  - Input: `userID`, `message`, `snapshot`, `goals`
  - Output: `AssistantThread`
  - Ownership: server creates thread documents, AI usage logs, and draft artifacts

- `generateGoalPlan`
  - Input: `userID`, `goal`, `timelineWeeks`
  - Output: `GoalPlanDraft`
  - Ownership: server generates and stores draft plans in `goalPlans`

- `commitAssistantDraft`
  - Input: `userID`, `action`
  - Output: `{ success: true }`
  - Ownership: server validates that the pending draft exists before confirming it

- `importSyllabusText`
  - Input: `userID`, `text`
  - Output: `ImportJob`
  - Ownership: server parses and normalizes raw text into courses and assignments

- `importSyllabusFile`
  - Input: `userID`, `sourceName`, `uploadedPath`, `extractedText`
  - Output: `ImportJob`
  - Ownership: server normalizes file-derived content and stores the job in `imports`

- `commitImportJob`
  - Input: `userID`, `job`
  - Output: `{ success: true }`
  - Ownership: server performs the cross-document write into `courses` and `assignments`

- `deleteImportJob`
  - Input: `userID`, `job.id`
  - Output: `{ success: true }`
  - Ownership: server loads the stored import job, removes import metadata, and only deletes associated uploaded source files under the authenticated user's import prefix

- `syncRevenueCatSubscription`
  - Input: `userID`
  - Output: `{ success: true }`
  - Ownership: server verifies current RevenueCat subscriber status with the secret API key and updates `subscriptions/current`

- `exportUserData`
  - Input: `userID`
  - Output: root profile data, exported user-scoped collections, and sanitized user-related system metadata
  - Ownership: server-authoritative export job boundary

- `deleteUserAccount`
  - Input: `userID`
  - Output: `{ success: true, userID, deletedCollections, redactedSystemCollections, deletedStoragePrefix }`
  - Ownership: server-authoritative deletion boundary

## Request authentication

- The iOS app calls these endpoints with `POST` JSON requests.
- The app sends the current Firebase ID token as `Authorization: Bearer <token>`.
- The app sends the current Firebase App Check token as `X-Firebase-AppCheck: <token>`.
- Each endpoint validates the token and rejects any `userID` mismatch.
- The backend verifies App Check in `monitor` or `enforce` mode through `APP_CHECK_MODE`. Use `monitor` while registering/debugging App Check, then `enforce` after verified traffic is confirmed.

## Public webhook endpoint

- `revenueCatWebhook`
  - Input: RevenueCat webhook payload
  - Output: `{ success: true }`
  - Ownership: server writes subscription snapshots, handles RevenueCat user aliases/transfers, and deduplicates processed webhook events
  - Security: protect it with the exact authorization header value configured in RevenueCat and mirrored in `REVENUECAT_WEBHOOK_SECRET`

## Calling conventions

- The app automatically attaches the current Firebase ID token as `Authorization: Bearer <token>` when the user is signed in.
- The app treats these functions as the only path for AI work, privileged writes, import commits, account export/deletion, and billing-derived state updates.
- `revenueCatWebhook` is the only unauthenticated HTTP endpoint.

## Server-owned collections

- `assistantThreads`
- `aiDrafts`
- `aiUsage`
- `aiUsageDaily`
- `goalPlans`
- `imports`
- `subscriptions`
- `aiUsageLogs`
- `assistantDraftArtifacts`
