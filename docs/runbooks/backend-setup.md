# Backend Setup Runbook

## Local setup

1. Install Node.js 20 and use `npx -y firebase-tools@latest` for Firebase CLI commands.
2. Copy `.firebaserc.template` to `.firebaserc` and set your Firebase project IDs.
3. Install dependencies in `backend/functions`.
4. Copy `iOSApp/Resources/Config/Secrets.template.xcconfig` to `iOSApp/Resources/Config/Secrets.xcconfig` for local overrides and fill in:
   - `API_BASE_URL`
   - `AI_API_BASE_URL`
   - `REVENUECAT_API_KEY`
   - `SUPERWALL_API_KEY`
   - `GOOGLE_CLIENT_ID`
   - `GOOGLE_REVERSED_CLIENT_ID`
5. Add a real `GoogleService-Info.plist` from the Firebase console to `iOSApp/Resources/Config/` for local Firebase initialization, and make sure it matches the registered iOS app bundle ID.
6. Set `API_BASE_URL` to your Firebase Functions root, for example:
   - `https://us-central1-your-project-id.cloudfunctions.net/`
   Set `AI_API_BASE_URL` to the same Firebase Functions root for the Genkit AI router:
   - `https://us-central1-your-project-id.cloudfunctions.net/`
7. Enable required Google Cloud APIs before first backend deploy:
   - Cloud Functions API
   - Cloud Build API
   - Artifact Registry API
   - Cloud Run Admin API
8. Set function secrets with the Firebase CLI before deploying:
   - `npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_SECRET`
   - `npx -y firebase-tools@latest functions:secrets:set REVENUECAT_SECRET_API_KEY`
9. Set subscription product ID environment variables for better backend plan mapping:
   - `REVENUECAT_MONTHLY_PRODUCT_ID`
   - `REVENUECAT_ANNUAL_PRODUCT_ID`
10. Set App Check and quota environment variables for the functions runtime:
   - `APP_CHECK_MODE=monitor` for first rollout.
   - Change to `APP_CHECK_MODE=enforce` only after verified App Check traffic appears in Firebase metrics and the debug simulator token has been registered.
   - Optional quota overrides: `AI_FREE_DAILY_LIMIT`, `AI_PREMIUM_DAILY_LIMIT`, and workflow-specific keys from `backend/config/.env.example`.
11. AI v1 runs through `backend/functions/src/ai/router.ts` with Genkit + Vertex AI Gemini. Use `AI_PROVIDER=stub` only for local smoke tests. Production and TestFlight functions should use `AI_PROVIDER=vertex` and `AI_ENABLE_STUB_FALLBACK=false`.
12. Deploy Firestore and Storage rules before enabling live client traffic.

## Required backend configuration

- `REVENUECAT_WEBHOOK_SECRET`
- `REVENUECAT_SECRET_API_KEY`
- `REVENUECAT_MONTHLY_PRODUCT_ID`
- `REVENUECAT_ANNUAL_PRODUCT_ID`
- `APP_CHECK_MODE`
- `AI_PROVIDER=vertex`
- `AI_MODEL=gemini-2.5-flash-lite`
- `AI_VERTEX_LOCATION=us-central1`
- `AI_ENABLE_STUB_FALLBACK=false`

## App Check rollout

1. In Firebase Console, register the iOS app for App Check with App Attest. Keep enforcement off while validating.
2. Build and run a Debug app. The Firebase App Check debug provider logs a debug token in the Xcode console.
3. Register that debug token in Firebase Console for the iOS app.
4. Deploy functions with `APP_CHECK_MODE=monitor`. In monitor mode, missing or invalid App Check tokens are logged but requests are not blocked.
5. Send one authenticated live request from the app, or run:

   ```bash
   FUNCTIONS_BASE_URL="https://us-central1-your-project-id.cloudfunctions.net/" \
   FIREBASE_ID_TOKEN="<firebase auth id token>" \
   FIREBASE_APP_CHECK_TOKEN="<app check token from the app runtime>" \
   SMOKE_USER_ID="<same uid as the id token>" \
   npm --prefix backend/functions run functions:live-smoke
   ```

6. Confirm Firebase App Check metrics show verified requests for the iOS app and that function logs do not show App Check monitor warnings for app-originated requests.
7. Switch the functions runtime to `APP_CHECK_MODE=enforce`, deploy functions, and repeat the smoke request. Missing or invalid tokens should now fail with 401.

Keep `APP_CHECK_MODE=monitor` until the dashboard registration and live app-originated request are both verified. The simulator requires a registered debug token; TestFlight/device builds use the App Attest provider with DeviceCheck fallback.

## RevenueCat webhook secret

- Configure RevenueCat to send an authorization header.
- Store the exact same header value in `REVENUECAT_WEBHOOK_SECRET`.
- The backend compares the incoming header string directly; do not strip prefixes unless your dashboard value excludes them.
- Store a RevenueCat secret API key in `REVENUECAT_SECRET_API_KEY` so the backend can verify subscription state after purchase/restore and during webhook processing.

## Deployment order

1. Firestore indexes and rules
2. Storage rules
3. Cloud Functions
4. App Check monitor verification
5. RevenueCat webhook target
6. App Check enforcement
