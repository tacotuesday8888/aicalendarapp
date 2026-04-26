# Cloud Functions API

## Authenticated JSON endpoints

- `assistantRespond`
- `generateGoalPlan`
- `commitAssistantDraft`
- `importSyllabusText`
- `importSyllabusFile`
- `commitImportJob`
- `deleteImportJob`
- `exportUserData`
- `deleteUserAccount`

## HTTP endpoints

- `revenueCatWebhook`

## Calling conventions

- The iOS app sends `POST` JSON requests to the Firebase Functions base URL in `API_BASE_URL`.
- The app automatically attaches the current Firebase ID token as `Authorization: Bearer <token>` when the user is signed in.
- Every authenticated endpoint receives a `userID` in the JSON body and validates it against the verified Firebase token on the server.
- `revenueCatWebhook` is the only public HTTP endpoint and should be protected with the configured RevenueCat authorization header value.
- The iOS app treats these functions as the only path for AI work, privileged writes, import commits, account export/deletion, and billing-derived state updates.
