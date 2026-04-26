# Round 1 — Summary

> Date: 2026-04-18
> Backend `npm run build` + `npm run lint` pass. No Swift linter errors on modified files.

---

## 1. Issues Solved


| #   | Issue                                                                                                                              | Why it mattered                                                                                        |
| --- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| 1   | Settings → Edit Profile dismissed the sheet **before** the async save completed                                                    | Users thought the save succeeded even on failure; only a tiny status row could later say otherwise     |
| 2   | Cold-start deep links (URL launches, push taps, paywall jumps) were lost if the route was set before `AppShellView` existed        | Deep links silently dropped on first launch                                                            |
| 3   | RevenueCat ran on anonymous IDs; never linked to the Firebase user                                                                 | Restores could pull a stranger's purchases; webhook (keyed by `app_user_id`) and client could disagree |
| 4   | `AppSessionViewModel.refreshSubscription()` swallowed errors                                                                       | A misconfigured RevenueCat could leave a user **stuck on the paywall forever** with no signal          |
| 5   | `PlannerService.observeSnapshot` ran 5 parallel observation tasks; on first error it threw but the other 4 kept running            | Leaked work + spurious yields after the stream finished                                                |
| 6   | Reflections allowed duplicate check-ins for the same moment on the same day; Today already gated this                              | Inconsistent product behavior + dirty data                                                             |
| 7   | Cloud Function `commitImportJob` wrote documents with the literal id `"undefined"` when `course.id` / `assignment.id` were missing | Firestore data corruption                                                                              |
| 8   | RevenueCat webhook accepted **anonymous POSTs** when `REVENUECAT_WEBHOOK_SECRET` env var was missing                               | Anyone could fabricate billing events in production                                                    |
| 9   | `notifications/dispatch.ts` (real FCM `send`) was implemented but **never exported** from `index.ts` and had no callers            | Server could not push to users                                                                         |
| 10  | Apple Sign-In nonce called `fatalError` if `SecRandomCopyBytes` failed                                                             | Rare random-byte failure crashed the entire app                                                        |


---

## 2. How They Were Solved


| #   | Change                                                                                                                                                                                                                                                                                                                                     | Why correct                                                                                 | Status                                              |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| 1   | `SettingsViewModel.saveProfile` now **throws**. `ProfileEditorSheet` calls it with `try await`, shows a `ProgressView` + disabled fields while saving, displays an in-sheet error on failure, and only calls `dismiss()` after success. `interactiveDismissDisabled` blocks swipe-to-dismiss mid-save.                                     | Save is now atomic from the user's perspective; failures are visible in the sheet           | ✅ Fully resolved                                    |
| 2   | Extracted `applyPendingRoute()` and called it from **both** `.onAppear` and `.onChange` on `AppShellView`. Route is cleared after consumption.                                                                                                                                                                                             | Cold start and live updates both apply the route exactly once                               | ✅ Fully resolved                                    |
| 3   | Added `linkUser` / `unlinkUser` to `SubscriptionServicing`. `SubscriptionService` caches the linked user id (under a lock) and only calls `Purchases.shared.logIn(uid)` / `logOut()` when (a) the id changes and (b) `Purchases.isConfigured`. `AppSessionViewModel.observeAuth` calls `linkUser` on sign-in and `unlinkUser` on sign-out. | RC identity now follows Firebase identity. Idempotent; safe before RC is configured.        | ✅ Fully resolved (real-world test requires RC keys) |
| 4   | Added `subscriptionRefreshError` and `isRefreshingSubscription` to `AppSessionViewModel`. `refreshSubscription()` populates them. `PaywallView` accepts these and shows a banner with a Retry button when set.                                                                                                                             | The user can no longer be silently locked out; they always have a path forward              | ✅ Fully resolved                                    |
| 5   | `PlannerObservationState` now also tracks the 5 sibling tasks. On first error it cancels the others before finishing the stream. The shell registers the tasks back into the actor immediately after spawning them.                                                                                                                        | Bounded resource use; no zombie tasks after a failure                                       | ✅ Fully resolved                                    |
| 6   | Added `hasCheckedIn(for:)` to `ReflectionsViewModel` (mirrors `TodayViewModel`). `saveCheckIn` returns early with a clear message; the Save button is disabled and a hint is shown when the moment is already taken today.                                                                                                                 | Behavior matches Today; users get a clear reason instead of a silent duplicate              | ✅ Fully resolved                                    |
| 7   | Added `sanitizeID()` helper that rejects empty / `"undefined"` / `"null"` and replaces `/`. When the parsed id is invalid, the function falls back to a fresh Firestore-generated id. The sanitized id is also written back into the document body so client and server stay consistent.                                                   | No more `"undefined"` doc ids; client model id == Firestore doc id                          | ✅ Fully resolved                                    |
| 8   | The webhook now **fails fast** with `503` and a logged error if `REVENUECAT_WEBHOOK_SECRET` is unset. Header check follows.                                                                                                                                                                                                                | Closes the open-endpoint hole. Operator gets a loud signal to set the secret.               | ✅ Fully resolved                                    |
| 9   | Created `notifications/triggers.ts` with `onStudySessionCompleted` Firestore trigger (fires only on the rising edge `* → completed`, calls `sendPushNotificationToUser`). Created `notifications/sendTestPush.ts` callable for end-to-end testing. Both exported from `index.ts`.                                                          | `dispatch.ts` is now reachable from a real trigger and from the iOS client for verification | ✅ Fully resolved (real push needs APNs setup)       |
| 10  | `randomNonceString()` is now `throws`. On `SecRandomCopyBytes` failure it returns `AppError.unknown(...)` instead of crashing. `start()` propagates the error to the caller. Also tightened the random-byte loop.                                                                                                                          | Recoverable failure replaces a crash; the auth flow surfaces an error the user can retry    | ✅ Fully resolved                                    |


---

## 3. Future Plan

### What I will fix next (code, no blockers)


| Order | Item                                                                                                 |
| ----- | ---------------------------------------------------------------------------------------------------- |
| 1     | Today: separate state for check-in mood vs vibe mood (currently shared)                              |
| 2     | Goals: per-goal "Generate plan" disable + serialize reorder writes                                   |
| 3     | Reflections / Imports / Goals: in-flight guards (no double-submit)                                   |
| 4     | Sessions: per-session timer (replace always-on 1 Hz publisher); scaled font for the timer label      |
| 5     | Calendar: adaptive day timeline (replace fixed 560pt)                                                |
| 6     | Onboarding: real review/edit step before committing syllabus parse                                   |
| 7     | Settings: in-app **data export** UI wired to existing `exportUserData` Cloud Function                |
| 8     | Sessions: implement attachment picker / upload / list / delete (model exists; UI missing)            |
| 9     | Storage service: persist Firebase Storage uploads only; fail loudly when not configured              |
| 10    | Reconcile `IPHONEOS_DEPLOYMENT_TARGET` (project 26.2 vs target 17.0)                                 |
| 11    | Author `aicalendarapp.entitlements` (Push, Sign in with Apple) and `PrivacyInfo.xcprivacy`           |
| 12    | Add CI: SwiftPM build/tests + backend `npm ci && build && lint`                                      |
| 13    | Refactor `AppContainer.live()` toward constructor injection                                          |
| 14    | Remove or `#if DEBUG`-gate the insecure non-Firebase email auth + the hard-coded Google demo profile |


### What I am currently blocked on (need a decision or a key from you)


| Blocker                                   | Action needed                                                                                                                                                                                 |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **M1 — Firestore rules vs client writes** | Pick **Option A** (route AI / plan / import writes through Cloud Functions) or **Option B** (relax rules with strict server-side validation). I cannot complete this fix without a direction. |
| **Real LLM behavior**                     | Provide `AI_PROVIDER` / `AI_MODEL` / `AI_ENDPOINT` / `AI_API_KEY` for the Functions runtime                                                                                                   |
| **Live Firebase integration**             | Real Firebase project + `GoogleService-Info.plist` + `.firebaserc`                                                                                                                            |
| **Truthful paywall testing**              | RevenueCat account + iOS SDK key + Offerings/Products/Entitlements                                                                                                                            |
| **Live Apple/Google sign-in testing**     | Apple Developer + Google OAuth iOS client (`GOOGLE_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`)                                                                                                   |
| **Real push end-to-end**                  | Apple Developer Push capability + APNs key linked to Firebase Messaging                                                                                                                       |
| **Webhook security in prod**              | `REVENUECAT_WEBHOOK_SECRET` set in Functions runtime                                                                                                                                          |
| **TestFlight / launch**                   | Apple Developer account, App Store Connect record, IAP products, privacy policy URL, ToS URL, account-deletion landing URL, App Privacy questionnaire                                         |


---

## State after Round 1

- **Code:** 10 critical bugs fixed, backend compiles + lints clean, no new linter errors.
- **Architecture:** identity (Firebase ↔ RC), routing (deep links), persistence reliability (planner observation, profile save), and server-side safety (webhook secret, dispatch wired, doc-id sanitization) are all materially better.
- **Still open:** M1 (architecture decision) plus all integration items that require your external accounts/keys.