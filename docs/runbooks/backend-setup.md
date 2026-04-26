# Backend Setup Runbook

## Local setup

1. Install Node.js 20 and use `npx -y firebase-tools@latest` for Firebase CLI commands.
2. Copy `.firebaserc.template` to `.firebaserc` and set your Firebase project IDs.
3. Install dependencies in `backend/functions`.
4. Copy `aicalendarapp/Resources/Config/Secrets.template.xcconfig` to `aicalendarapp/Resources/Config/Secrets.xcconfig` for local overrides and fill in:
   - `API_BASE_URL`
   - `REVENUECAT_API_KEY`
   - `SUPERWALL_API_KEY`
   - `GOOGLE_CLIENT_ID`
   - `GOOGLE_REVERSED_CLIENT_ID`
5. Add a real `GoogleService-Info.plist` from the Firebase console to `aicalendarapp/Resources/Config/` for local Firebase initialization, and make sure it matches the registered iOS app bundle ID.
6. Set `API_BASE_URL` to your Firebase Functions root, for example:
   - `https://us-central1-your-project-id.cloudfunctions.net/`
7. Enable required Google Cloud APIs before first backend deploy:
   - Cloud Functions API
   - Cloud Build API
   - Artifact Registry API
   - Cloud Run Admin API
8. Set function secrets with the Firebase CLI before deploying:
   - `npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_SECRET`
   - `npx -y firebase-tools@latest functions:secrets:set REVENUECAT_SECRET_API_KEY`
9. Provide the AI runtime configuration values required by `backend/functions/src/ai/provider.ts` in your chosen Functions runtime configuration flow:
   - `AI_PROVIDER`
   - `AI_MODEL`
   - `AI_ENDPOINT`
   - `AI_API_KEY`
10. Deploy Firestore and Storage rules before enabling live client traffic.

## Required backend configuration

- `AI_PROVIDER`
- `AI_MODEL`
- `AI_ENDPOINT`
- `AI_API_KEY`
- `REVENUECAT_WEBHOOK_SECRET`
- `REVENUECAT_SECRET_API_KEY`

## RevenueCat webhook secret

- Configure RevenueCat to send an authorization header.
- Store the exact same header value in `REVENUECAT_WEBHOOK_SECRET`.
- The backend compares the incoming header string directly; do not strip prefixes unless your dashboard value excludes them.
- If you want canonical subscription state sync after webhook receipt, store a RevenueCat secret API key in `REVENUECAT_SECRET_API_KEY`.

## Deployment order

1. Firestore indexes and rules
2. Storage rules
3. Cloud Functions
4. RevenueCat webhook target
