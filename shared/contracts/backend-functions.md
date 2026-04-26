# Backend Function Contracts

These authenticated JSON HTTP and webhook endpoints are the server boundary for privileged logic.

The iOS app sends `POST` JSON requests to the Firebase Functions base URL in `API_BASE_URL`. Authenticated endpoints receive a `userID` in the JSON body and validate it against the verified Firebase token on the server.

## Authenticated JSON endpoints

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
  - Input: `userID`, `job.id`, `job.uploadedFilePath`
  - Output: `{ success: true }`
  - Ownership: server removes import metadata and associated uploaded source files

- `exportUserData`
  - Input: `userID`
  - Output: root profile data plus exported user-scoped collections
  - Ownership: server-authoritative export job boundary

- `deleteUserAccount`
  - Input: `userID`
  - Output: `{ success: true, userID, deletedCollections, deletedUploadedFiles }`
  - Ownership: server-authoritative deletion boundary

## Request authentication

- The iOS app calls these endpoints with `POST` JSON requests.
- The app sends the current Firebase ID token as `Authorization: Bearer <token>`.
- Each endpoint validates the token and rejects any `userID` mismatch.

## Public webhook endpoint

- `revenueCatWebhook`
  - Input: RevenueCat webhook payload
  - Output: `{ success: true }`
  - Ownership: server writes subscription snapshots and deduplicates processed webhook events
  - Security: protect it with the exact authorization header value configured in RevenueCat and mirrored in `REVENUECAT_WEBHOOK_SECRET`

## Calling conventions

- The app automatically attaches the current Firebase ID token as `Authorization: Bearer <token>` when the user is signed in.
- The app treats these functions as the only path for AI work, privileged writes, import commits, account export/deletion, and billing-derived state updates.
- `revenueCatWebhook` is the only public HTTP endpoint.

## Server-owned collections

- `assistantThreads`
- `goalPlans`
- `imports`
- `subscriptions`
- `aiUsageLogs`
- `assistantDraftArtifacts`
