# AI Efficiency Calendar Beta Readiness

This public checklist covers safe setup and verification steps that do not expose private project notes, credentials, signing assets, or account-specific identifiers.

## Current Beta Definition

The app is beta-ready when a signed iPhone build can complete these flows with a disposable test account:

- Sign in with Firebase Auth using email/password, Apple, or Google.
- Complete onboarding and reload into the signed-in app state.
- Create, edit, complete, delete, and relaunch-check goals, planner blocks, sessions, reflections, and reminders.
- Import selected Apple Calendar events after explicit calendar permission.
- Run premium AI workflows through Firebase Functions with `AI_PROVIDER=vertex`, `AI_MODEL=gemini-3.1-flash-lite`, and `AI_ENABLE_STUB_FALLBACK=false`.
- Purchase or restore through RevenueCat, sync the backend subscription snapshot, and gate premium AI workflows from the server.
- Present Superwall placements with the same Firebase UID and RevenueCat entitlement state used by the rest of the app.
- Export user data and safely delete only disposable test accounts.

## Required Local Tools

- Xcode 26 or newer with an iOS simulator runtime.
- Node.js 22 for Firebase Functions.
- Java 21 for Firebase emulator rules tests.
- Firebase CLI, installed on demand by the npm scripts.

On this Mac, Homebrew OpenJDK is available at `/opt/homebrew/opt/openjdk@21/bin/java`. If `java -version` fails, run rules tests with:

```bash
PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" npm --prefix backend/functions run rules:test
```

## Public Config Templates

Do not commit real config files. Copy these templates locally and fill them from the service dashboards:

- `.firebaserc.template` -> `.firebaserc`
- `iOSApp/Resources/Config/GoogleService-Info.plist.template` -> `iOSApp/Resources/Config/GoogleService-Info.plist`
- `iOSApp/Resources/Config/Secrets.template.xcconfig` -> `iOSApp/Resources/Config/Secrets.xcconfig`
- `backend/config/.env.example` -> local Functions environment or Firebase secrets

The RevenueCat entitlement ID is not a secret, but it must match exactly in iOS config and backend config:

```text
REVENUECAT_ENTITLEMENT_ID = aiefficiencyapp Pro
REVENUECAT_ENTITLEMENT_ID=aiefficiencyapp Pro
```

## Firebase and Backend Setup

1. Create or select the Firebase project for the beta environment.
2. Add the iOS app using the bundle ID from `iOSApp/Resources/Config/Release.xcconfig`.
3. Download `GoogleService-Info.plist` and place it at `iOSApp/Resources/Config/GoogleService-Info.plist`.
4. Enable Firebase Auth providers needed for beta: email/password, Apple, and Google.
5. Deploy Firestore rules, Storage rules, indexes, and Functions only after local checks pass.
6. Keep `APP_CHECK_MODE=monitor` until debug tokens and App Attest are verified in Firebase App Check. Move to `APP_CHECK_MODE=enforce` only after signed builds send valid App Check tokens.
7. Production/TestFlight AI config must use:

```text
AI_PROVIDER=vertex
AI_MODEL=gemini-3.1-flash-lite
AI_VERTEX_LOCATION=global
AI_ENABLE_STUB_FALLBACK=false
```

## RevenueCat and Superwall Setup

RevenueCat is the subscription source of truth. Superwall handles placements and paywall presentation, but purchases must flow through RevenueCat.

1. In RevenueCat, create the iOS app and entitlement named exactly `aiefficiencyapp Pro`, unless all app/backend config is changed to the new exact name.
2. Add monthly and annual products after App Store Connect product IDs exist.
3. Add the RevenueCat public iOS SDK key to `Secrets.xcconfig` as `REVENUECAT_API_KEY`.
4. Add the RevenueCat secret API key to Functions runtime as `REVENUECAT_SECRET_API_KEY`.
5. Configure the RevenueCat webhook URL to the deployed `revenueCatWebhook` function.
6. Set the RevenueCat webhook Authorization header and store the same exact value as `REVENUECAT_WEBHOOK_SECRET`.
7. In Superwall, create placements matching `PaywallTrigger` raw values in `iOSApp/Core/Models/AppModels.swift`.
8. Add the Superwall public API key to `Secrets.xcconfig` as `SUPERWALL_API_KEY`.
9. Verify a signed beta build identifies Superwall with the Firebase UID and that RevenueCat restore/purchase changes update Superwall subscription status.

## Verification Commands

Run these before merging release-readiness work:

```bash
npm --prefix backend/functions run lint
npm --prefix backend/functions run typecheck:scripts
npm --prefix backend/functions run build
AI_PROVIDER=stub npm --prefix backend/functions run ai:smoke
LIVE_SMOKE_DRY_RUN=true LIVE_SMOKE_INCLUDE_PREMIUM_AI=true FUNCTIONS_BASE_URL=https://example.invalid/functions npm --prefix backend/functions run functions:live-smoke
PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH" npm --prefix backend/functions run rules:test
bash scripts/ci_ios.sh
```

`npm --prefix backend/functions audit --omit=dev --audit-level=moderate` currently reports upstream Genkit/Firebase transitive OpenTelemetry and `uuid` advisories. Do not force `npm audit fix --force` without first confirming Firebase Functions and Genkit peer compatibility.

Live smoke tests need a deployed Functions base URL, disposable Firebase ID token, optional App Check token, and a disposable test user:

```bash
FUNCTIONS_BASE_URL=https://<region>-<project-id>.cloudfunctions.net \
FIREBASE_ID_TOKEN=<disposable-test-id-token> \
SMOKE_USER_ID=<disposable-test-user-uid> \
FIREBASE_APP_CHECK_TOKEN=<debug-or-app-attest-token-if-enforced> \
npm --prefix backend/functions run functions:live-smoke
```

`FIREBASE_APP_CHECK_TOKEN` is required only after `APP_CHECK_MODE=enforce`; while App Check is in monitor mode, the smoke script warns when it is omitted.

The default live smoke matrix checks non-destructive backend health: vibe feedback, RevenueCat subscription sync, and data export. After the disposable test user has premium access through RevenueCat or the Functions runtime variable `BETA_PRO_USER_IDS`, also run the premium AI matrix:

```bash
FUNCTIONS_BASE_URL=https://<region>-<project-id>.cloudfunctions.net \
FIREBASE_ID_TOKEN=<disposable-premium-test-id-token> \
FIREBASE_APP_CHECK_TOKEN=<debug-or-app-attest-token-if-enforced> \
SMOKE_USER_ID=<disposable-premium-test-user-uid> \
LIVE_SMOKE_INCLUDE_PREMIUM_AI=true \
npm --prefix backend/functions run functions:live-smoke
```

Before running the premium matrix against the deployed backend, confirm the deployed Functions environment has live AI enabled:

```text
AI_PROVIDER=vertex
AI_MODEL=gemini-3.1-flash-lite
AI_VERTEX_LOCATION=global
AI_ENABLE_STUB_FALLBACK=false
```

For beta allowlist testing, also set:

```text
BETA_PRO_USER_IDS=<same disposable Firebase UID as SMOKE_USER_ID>
```

If using a real RevenueCat sandbox/test entitlement instead, `BETA_PRO_USER_IDS` can be omitted, but the disposable user must sync as `entitlement=active` before the AI calls run.

This intentionally creates AI usage records plus assistant, goal-plan, and syllabus-import review draft documents for the disposable user, then verifies those documents through `exportUserData`. The script expects new premium AI usage records with `provider=vertex` and `model=gemini-3.1-flash-lite`; override those checks only when deliberately smoke-testing a different model with `SMOKE_EXPECTED_AI_PROVIDER` and `SMOKE_EXPECTED_AI_MODEL`. If it fails with a premium or permission error, confirm the ID token belongs to `SMOKE_USER_ID`, the user has an active RevenueCat entitlement or is listed in `BETA_PRO_USER_IDS`, and App Check is still in monitor mode or the provided token is valid.

## Remaining External Blockers

- Apple Developer enrollment, certificates, identifiers, capabilities, App Store Connect app record, StoreKit products, and TestFlight upload.
- Real Firebase project configuration and deployed Functions secrets.
- RevenueCat products, entitlement, offering, API keys, and webhook secret.
- Superwall project, API key, placements, and paywall configuration.
- GitHub branch protection and CodeQL/CI results after the first public workflow run.
- Designer UI handoff for final visual polish.
