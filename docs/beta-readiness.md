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
5. Deploy Firestore rules, Storage rules, indexes, and Functions only after local checks pass:

```bash
npm --prefix backend/functions run deploy:backend
```

Do not use a Functions-only deploy for beta unless rules and indexes have already been deployed from the same commit.

6. Keep the custom Functions runtime variable `APP_CHECK_MODE=monitor` until debug tokens and App Attest are verified in Firebase App Check. Move to `APP_CHECK_MODE=enforce` only after signed builds send valid App Check tokens.
7. Separately monitor and enable Firebase product-level App Check enforcement in the Firebase Console for each supported product that exposes enforcement controls, including Cloud Functions, Firestore, Storage, and Auth/Identity flows. The `APP_CHECK_MODE` variable only controls the app's custom HTTPS Functions guard; it does not enable product enforcement by itself.
8. Production/TestFlight AI config must use:

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

Local iOS CI uses the ignored `.build/ci-ios` directory for DerivedData and SwiftPM package cache reuse. If package resolution gets stuck on stale local package state, rerun with `RESET_IOS_CI_PACKAGES=true bash scripts/ci_ios.sh`. GitHub Actions uses its temporary runner directory and resets package state automatically.

Also run dependency-audit triage before beta/release work:

```bash
npm --prefix backend/functions run audit:production
```

This audit is currently expected to exit nonzero because it reports upstream Genkit/Firebase transitive OpenTelemetry and `uuid` advisories. Treat it as a tracked release-risk review, not a merge-blocking local verification check, until a compatible upstream fix or tested targeted override is available. Do not force `npm audit fix --force` without first confirming Firebase Functions and Genkit peer compatibility.

As of June 19, 2026, the open Dependabot alerts are:

- `@opentelemetry/auto-instrumentations-node` high severity, fixed upstream at `0.75.0`.
- `@opentelemetry/sdk-node` high severity, fixed upstream at `0.217.0`.
- `@opentelemetry/core` medium severity, fixed upstream at `2.8.0`.
- `uuid` medium severity, fixed upstream at `11.1.1`.

Dependabot cannot currently produce safe PRs for these alerts. The `uuid` alert is constrained by the current Genkit/Firebase dependency tree, and the OpenTelemetry fix path would downgrade `@genkit-ai/google-genai` from `1.37.0` to `1.16.1`. A Dependabot PR for `firebase-admin@14.0.0` was also closed because `firebase-functions@7.2.5` only accepts `firebase-admin` `^11.10.0 || ^12.0.0 || ^13.0.0`. Keep these as monitored upstream dependency risks until compatible Firebase/Genkit releases are available or a targeted override has been tested through backend CI, rules tests, and live smoke.

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

This intentionally creates AI usage records plus assistant, goal-plan, and syllabus-import review draft documents for the disposable user, commits the generated syllabus import, and verifies the resulting course and assignment records through `exportUserData`. The script expects new premium AI usage records with `provider=vertex` and `model=gemini-3.1-flash-lite`; override those checks only when deliberately smoke-testing a different model with `SMOKE_EXPECTED_AI_PROVIDER` and `SMOKE_EXPECTED_AI_MODEL`. If it fails with a premium or permission error, confirm the ID token belongs to `SMOKE_USER_ID`, the user has an active RevenueCat entitlement or is listed in `BETA_PRO_USER_IDS`, and App Check is still in monitor mode or the provided token is valid.

## Remaining External Blockers

- Apple Developer enrollment, certificates, identifiers, capabilities, App Store Connect app record, StoreKit products, and TestFlight upload.
- Real Firebase project configuration and deployed Functions secrets.
- RevenueCat products, entitlement, offering, API keys, and webhook secret.
- Superwall project, API key, placements, and paywall configuration.
- App Check signed-build validation and Firebase product-level enforcement rollout.
- APNS key/certificate setup and signed push-notification testing.
- Upstream dependency fixes for the currently unresolved Genkit/Firebase transitive OpenTelemetry and `uuid` advisories.
- Existing public Git history includes older private planning/runbook documents that are no longer present in the current tree. The current tree is public-safe, but removing historical docs requires an explicit approved history rewrite or a fresh snapshot repository.
- Designer UI handoff for final visual polish.

## Completed Repository Readiness Items

- Repository visibility is public and GitHub Actions are enabled.
- GitHub Dependabot alerts, Dependabot security updates, secret scanning, secret scanning push protection, and private vulnerability reporting are enabled for the repository.
- Branch protection is enabled on `main`, requiring strict up-to-date backend, iOS, and CodeQL checks before merge.
- CodeQL and backend/iOS CI workflows have passed on public PRs and merged `main`; each workflow now runs on every PR and self-skips unrelated work so required checks are not left missing on docs-only changes.
- Dependabot update schedules are configured for GitHub Actions, backend npm dependencies, and Swift Package Manager.
- GitHub secret-scanning and code-scanning alert APIs currently return no open alerts; the open Dependabot dependency alerts are tracked in the verification section above.
- Current tracked tree secret scan has no known credential matches; real local config files remain ignored and untracked.
