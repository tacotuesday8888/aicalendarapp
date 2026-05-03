# App Check Enforcement Rollout

Date: 2026-04-28
Status: monitor mode. Do not flip to enforcement until the criteria below are met.

## Official Alignment

Relevant official Firebase guidance:

- App Check protects backend resources by rejecting requests that do not carry a valid app attestation once enforcement is enabled: https://firebase.google.com/docs/app-check
- Custom backends should verify the `X-Firebase-AppCheck` token with the Firebase Admin SDK: https://firebase.google.com/docs/app-check/custom-resource-backend
- The Apple debug provider must be used only for debug/CI, and debug tokens must be kept private: https://firebase.google.com/docs/app-check/ios/debug-provider
- Cloud Functions callable enforcement uses `enforceAppCheck`; this app uses HTTPS `onRequest` functions, so the code currently verifies App Check manually in `backend/functions/src/shared/appCheck.ts`: https://firebase.google.com/docs/app-check/cloud-functions

Current app alignment:

- Debug builds set `AppCheckDebugProviderFactory()` before Firebase is used.
- Release builds use `AppAttestProvider`, falling back to `DeviceCheckProvider`.
- Backend HTTPS requests send the `X-Firebase-AppCheck` header from `NetworkService`.
- Backend Functions verify App Check tokens through the Admin SDK helper.
- Backend `APP_CHECK_MODE` remains `monitor`, so missing/invalid tokens are logged but not rejected.

## Why Monitor Mode Stays On For Now

Monitor mode is intentional until real-device App Check tokens are verified across:

- Email/password auth flows.
- Google sign-in flows.
- Firestore-backed app sessions.
- Storage uploads for syllabus import.
- `ai/run`.
- `syncRevenueCatSubscription`.
- Account export and delete.

Flipping enforcement before this testing can lock out valid users if release entitlements, bundle ID, Firebase app registration, debug tokens, or App Attest/DeviceCheck behavior are misconfigured.

## Debug Token Testing Steps

1. Open Xcode.
2. Select the app scheme.
3. Go to Product > Scheme > Edit Scheme.
4. Select Run > Arguments.
5. Add `-FIRDebugEnabled` under Arguments Passed On Launch.
6. Run the app in the iOS Simulator.
7. Trigger a Firebase-backed request, such as sign-in or an AI/backend call.
8. In the Xcode console, find the line containing `Firebase App Check Debug Token`.
9. Copy the debug token. Treat it as sensitive.
10. Open Firebase Console: https://console.firebase.google.com/project/aieffciencyapp/appcheck
11. Find the iOS app.
12. Open the app overflow menu.
13. Choose Manage debug tokens.
14. Add the copied token with a clear label, such as `local-simulator-langqi`.
15. Re-run the same app request and confirm backend logs no longer show `App Check verification failed in monitor mode` for that request.

## Real Device Testing Steps

1. Build a Debug build to a physical iPhone.
2. Confirm Firebase config uses bundle ID `com.langqi.aicalendarapp`.
3. Sign in with email/password.
4. Sign out and sign in with Google.
5. Create or update one simple app record, such as a goal or planner block.
6. Run a backend call that does not require paid AI, such as export data for a test account.
7. Run a safety-path `ai/run` smoke request if needed, using a test account and avoiding paid AI where possible.
8. Check Functions logs for the tested routes.
9. Confirm no App Check monitor warnings appear for valid app requests.

## Criteria To Flip Enforcement

Do not set `APP_CHECK_MODE=enforce` until all are true:

- Debug simulator token is registered and verified.
- At least one real iPhone succeeds with App Attest or DeviceCheck in Release/TestFlight-like configuration.
- Email/password and Google sign-in flows both reach protected backend endpoints successfully.
- Firestore, Storage, `ai/run`, account export/delete, and subscription sync work from the app without App Check warnings.
- Functions logs show zero App Check monitor failures for valid app traffic over a representative test window.
- There is a rollback command ready to set `APP_CHECK_MODE=monitor` and redeploy Functions if valid users are blocked.

## Enforcement Flip Procedure

Requires explicit approval before execution.

1. Set the deployed Functions environment to `APP_CHECK_MODE=enforce`.
2. Deploy Functions.
3. Run unauthenticated probes and confirm they still fail.
4. Run authenticated app requests from simulator debug token and real device.
5. Tail Functions logs for App Check errors.
6. If valid app traffic fails, immediately revert to `APP_CHECK_MODE=monitor` and redeploy.

## Current Blocker

The current blocker is not code. It is verification: App Check tokens from simulator and real device need to be registered/tested before enforcement is safe.
