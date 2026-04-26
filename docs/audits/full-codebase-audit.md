# Full Codebase & Project Readiness Audit

> Date: 2026-04-18
> Scope: `aicalendarapp/` iOS app + `backend/functions` + `backend/firestore` + `backend/storage` + project config.
> Method: Direct file-by-file read of services, features, app shell, configs, rules, and Cloud Functions. Nothing is assumed working; every claim links to a file path / line range.

---

## TL;DR

- The Swift code **compiles and runs**, and most surfaces look “done” visually.
- Several layers **silently degrade** when keys are missing (Firebase, RevenueCat, API URL, Google client) — that hides real issues.
- There is a **structural mismatch**: the Firestore rules forbid client writes to `assistantThreads`, `goalPlans`, `imports`, `subscriptions`, etc., but the iOS local-fallback code paths **try to write them** when the API URL is missing or the call fails. With Firebase + a signed-in user, those writes return **permission denied**.
- **RevenueCat is not linked to Firebase user IDs**, so purchases / restores can be associated with the wrong account.
- **Push notification fan-out (`dispatch.ts`)** exists but is **not exported** from `index.ts` — push from server is dead code.
- **No entitlements file**, **no `PrivacyInfo.xcprivacy`**, **no real `GoogleService-Info.plist`**, **no `.firebaserc`**, **no signing config**, **no CI** — the project is **not turn-key buildable for distribution**.
- The **Settings → Edit Profile** sheet dismisses **before** the save completes, and the **deep-link `pendingRoute`** handling can miss cold-start routes.

This is a “feature-complete UI, integration-incomplete reality.” It needs a focused round of **integration correctness + non-code setup** before it can leave dev.

---

## 1. Codebase Audit

### Critical (block correctness or production)


| #   | Issue                                                       | Where                                                                                                                                          | What it does today                                                                                                                                                                                                                                                                                                                                                                               | What it should do                                                                                                                                                                                          |
| --- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1  | **Firestore rules vs client writes mismatch**               | `backend/firestore/firestore.rules` L32–60 + `aicalendarapp/Services/AI/BackendFunctionService.swift` L41, L70, L97, L109, L122, L131          | Rules deny client writes to `assistantThreads`, `goalPlans`, `imports`, `subscriptions`, `aiUsageLogs`, `assistantDraftArtifacts`. Client local-fallback code calls `databaseService.save(...)` for `assistantThreads`, `goalPlans`, `imports` whenever the backend is missing or returns nil. With Firebase enabled, those writes will **fail with permission denied** instead of falling back. | Either route those writes through a Cloud Function (server-only), or relax rules with a strict validator. Don’t silently rely on local fallbacks.                                                          |
| C2  | **Settings profile save dismisses before save completes**   | `aicalendarapp/Features/Settings/Views/SettingsFeature.swift` L312–316, L358–365                                                               | `ProfileEditorSheet`’s Save button calls `onSave(updated)` (which fires `Task { await viewModel.saveProfile(updated) }`) and then `dismiss()` immediately. The save is not awaited; if it fails, only `statusMessage` later shows it.                                                                                                                                                            | Disable Save while saving, await the call, dismiss on success, surface the error inside the sheet on failure.                                                                                              |
| C3  | **Cold-start deep link can be lost**                        | `aicalendarapp/App/Navigation/AppRootFeature.swift` L62–66 + `aicalendarapp/Features/Shell/Views/AppShellFeature.swift` L155–172               | `pendingRoute` is set by `handle(url:)` and handled only inside `onChange(of: pendingRoute)` in `AppShellView`. If the URL fires before `AppShellView` exists (cold start, paywall, onboarding), the route is set then never observed by the shell.                                                                                                                                              | Apply `pendingRoute` on `AppShellView.onAppear` (and clear it after), so cold-start routes are not dropped. Currently we already clear it after consumption (good) but never apply it on first appearance. |
| C4  | **RevenueCat not aliased to Firebase user**                 | `aicalendarapp/Services/MonetizationServices.swift` (no `Purchases.logIn`)                                                                     | RevenueCat uses anonymous IDs. Webhook in `backend/functions/src/billing/revenuecat.ts` writes by `app_user_id`. App and webhook can disagree. Restoring on a signed-in account may pull a stranger’s purchases or fail to restore.                                                                                                                                                              | After sign-in, call `Purchases.shared.logIn(user.id)`. After sign-out, `logOut`. Match `app_user_id` to Firebase UID.                                                                                      |
| C5  | **RevenueCat webhook can be open**                          | `backend/functions/src/billing/revenuecat.ts` L5–13                                                                                            | Validates `Authorization` only **if** `REVENUECAT_WEBHOOK_SECRET` env var is set. If not set, the endpoint accepts anonymous POSTs and updates billing state.                                                                                                                                                                                                                                    | Refuse to start the function (or always 401) if the secret is missing.                                                                                                                                     |
| C6  | **Push fan-out backend is dead code**                       | `backend/functions/src/notifications/dispatch.ts` + `backend/functions/src/index.ts`                                                           | `dispatch.ts` implements real FCM `getMessaging().send`, but `index.ts` does not export it. No trigger calls it. Server cannot push to users.                                                                                                                                                                                                                                                    | Export it as an HTTPS callable or a Firestore trigger and wire actual call sites (e.g. assignment due, plan assigned, session timer).                                                                      |
| C7  | **Subscription user can get stuck on paywall**              | `aicalendarapp/App/Navigation/AppRootFeature.swift` L31–42, L135–147 + `aicalendarapp/Services/MonetizationServices.swift` L58–76              | `refreshSubscription()` swallows errors. If `Purchases.configure` was skipped (empty key) or refresh fails, the state stays `.locked` and the user is **trapped** on the paywall.                                                                                                                                                                                                                | Distinguish “not configured” (dev) from “configured but failed” (show retry / contact support). Don’t silently lock.                                                                                       |
| C8  | **Cloud syllabus commit can write doc with id "undefined"** | `backend/functions/src/imports/syllabus.ts` L69–71                                                                                             | `doc(String(course.id ?? undefined))` produces the literal string `"undefined"` if `id` is absent, corrupting Firestore.                                                                                                                                                                                                                                                                         | Generate a stable ID (`uuid()` or sanitized course title) when `course.id` is missing.                                                                                                                     |
| C9  | **PlannerService leaks tasks on first error**               | `aicalendarapp/Services/FeatureServices.swift` ~L80–155                                                                                        | `observeSnapshot` spawns 5 parallel observation tasks. If one throws, the stream `finish(throwing:)` is called but the other 4 keep running.                                                                                                                                                                                                                                                     | Wrap in `withThrowingTaskGroup` or cancel siblings explicitly on first failure.                                                                                                                            |
| C10 | **No iOS entitlements file**                                | (search across project)                                                                                                                        | Project has no `.entitlements`. App requires Push, Sign in with Apple, possibly Background Modes (already in Info.plist). On distribution build the entitlements will fail / be absent.                                                                                                                                                                                                          | Create `aicalendarapp.entitlements` and link it in build settings. Add `aps-environment`, `com.apple.developer.applesignin`, etc.                                                                          |
| C11 | **No `PrivacyInfo.xcprivacy`**                              | (project root)                                                                                                                                 | Apple requires a privacy manifest for SDKs (Firebase, RevenueCat, GoogleSignIn) and certain APIs. App Store submission will be rejected without it.                                                                                                                                                                                                                                              | Add `PrivacyInfo.xcprivacy` declaring required reason APIs and tracking domains.                                                                                                                           |
| C12 | **Reflections lets users duplicate same check-in moment**   | `aicalendarapp/Features/Reflections/Views/ReflectionsFeature.swift` L59–76 vs `aicalendarapp/Features/Today/Views/TodayFeature.swift` L166–175 | Today gates check-ins via `availableCheckInMoment`, but Reflections’s `saveCheckIn` does not. Users can log the same moment twice from Reflections.                                                                                                                                                                                                                                              | Apply the same `availableCheckInMoment` rule (or a dedup at the service level).                                                                                                                            |


### Important (correctness, reliability, cleanup)


| #   | Issue                                                                                                                                                                                                     | Where                                                                                                                  |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| I1  | iOS deployment target inconsistent: project-level `IPHONEOS_DEPLOYMENT_TARGET = 26.2`, app target = `17.0`. Confusing and likely wrong.                                                                   | `aicalendarapp.xcodeproj/project.pbxproj`                                                                              |
| I2  | `OnboardingViewModel.load()` early-returns if `availableCalendars` is non-empty. After a transient failure, retry is impossible without recreating the VM.                                                | `Features/Onboarding/Views/OnboardingFeature.swift` L36–37                                                             |
| I3  | Onboarding `importSyllabus` does not check `isLoading` before starting — overlapping imports possible.                                                                                                    | `Features/Onboarding/Views/OnboardingFeature.swift` L61–76                                                             |
| I4  | Onboarding “Import selected calendars” and other long buttons not consistently disabled while `isLoading`.                                                                                                | `Features/Onboarding/Views/OnboardingFeature.swift` L150–153                                                           |
| I5  | Today shares `selectedMood` between check-in and vibe panels — logging a vibe overwrites mood meant for check-in.                                                                                         | `Features/Today/Views/TodayFeature.swift` L9–13, L333–398                                                              |
| I6  | Today single `errorMessage` for 3 concurrent observation streams — last error wins, others silent.                                                                                                        | `Features/Today/Views/TodayFeature.swift` L16, L49–77                                                                  |
| I7  | Goals: “Generate AI plan” disabled for **all** goals when **any** plan is loading.                                                                                                                        | `Features/Goals/Views/GoalsFeature.swift` L283–293                                                                     |
| I8  | Goals reorder fires unsequenced async writes — rapid drag can interleave conflicting orders.                                                                                                              | `Features/Goals/Views/GoalsFeature.swift` L162–178                                                                     |
| I9  | Sessions: 1 Hz `Timer.publish` runs whenever the Sessions tab is alive, regardless of an active session — battery cost.                                                                                   | `Features/Sessions/Views/SessionsFeature.swift` L165–166, L231                                                         |
| I10 | Sessions: timer label uses `.font(.system(size: 32, …))` — does not respect Dynamic Type.                                                                                                                 | `Features/Sessions/Views/SessionsFeature.swift` ~L345–348                                                              |
| I11 | Sessions: when sessions list is empty, both `SessionComposer` and `EmptyStateView` show — duplicate UX.                                                                                                   | `Features/Sessions/Views/SessionsFeature.swift` L191–201                                                               |
| I12 | Calendar day timeline uses fixed inner `ScrollView` height (560pt). Breaks on iPad / large dynamic type.                                                                                                  | `Features/Calendar/Views/CalendarFeature.swift` ~L420–469                                                              |
| I13 | Reflections `saveCheckIn` / `saveVibeCheck` have no in-flight guard — double-tap can duplicate writes.                                                                                                    | `Features/Reflections/Views/ReflectionsFeature.swift` L59–98                                                           |
| I14 | Reflections / Imports `delete` fires parallel `Task`s per row — list mutates while deletes run.                                                                                                           | `Features/Reflections/Views/ReflectionsFeature.swift` L100–139 / `Features/Imports/Views/ImportsFeature.swift` L92–116 |
| I15 | Imports `commit` button has no loading state — user can double-commit a job.                                                                                                                              | `Features/Imports/Views/ImportsFeature.swift` L70–90, L163–165                                                         |
| I16 | Storage falls back to `aicalendarapp-uploads` temp dir when Firebase Storage is missing — uploads not durable.                                                                                            | `Services/BackendServices.swift` L361–375                                                                              |
| I17 | `AppContainer.live()` uses global singletons + post-init mutation. Order-dependent, hard to test.                                                                                                         | `App/DependencyInjection/AppContainer.swift` L69–135                                                                   |
| I18 | Non-Firebase email/password auth stores **unsalted SHA256** of password in Keychain. Demo-grade; do not ship.                                                                                             | `Services/BackendServices.swift` L443–461                                                                              |
| I19 | Non-Firebase Google sign-in returns a hard-coded demo `UserProfile` if `GoogleSignIn` SDK isn’t linked. Looks real, isn’t.                                                                                | `Services/BackendServices.swift` L645–657                                                                              |
| I20 | `BackendFunctionService.commitAssistantDraft` local fallback creates new UUIDs for `GoalPlanDraft` / `PlannerBlock` instead of `request.action.id`, diverging from server.                                | `Services/AI/BackendFunctionService.swift` L87–112                                                                     |
| I21 | `OnboardingState.isComplete` is `didCompleteProfile && completedAt != nil`. Calendar / syllabus import are **not** required to finish onboarding (despite UI emphasis). Confirm if intentional.           | `Core/Models/AppModels.swift` L212–222                                                                                 |
| I22 | `PaywallView.task` calls `viewModel.prepare()` every time the view appears — re-registers Superwall triggers repeatedly.                                                                                  | `Features/Paywall/Views/PaywallFeature.swift` L29–32, L114–117                                                         |
| I23 | `AppShellView` tab roots capture `user` at construction. If session profile updates without rebuilding the shell, tab VMs keep stale `user`.                                                              | `Features/Shell/Views/AppShellFeature.swift` ~L88–108                                                                  |
| I24 | `PlannerAccumulator(referenceDate:)` ignores the date passed by `observeSnapshot(on:)`. Snapshot date is always built from `.now`. Misleading API; not a wrong-data bug today because UI filters locally. | `Services/FeatureServices.swift` ~L492–553                                                                             |
| I25 | `AssistantViewModel.start()` does not call `analyticsService.trackScreen("assistant")` (other features do).                                                                                               | `Features/Shell/Views/AppShellFeature.swift` L32–63                                                                    |


### Minor (polish / technical debt)

- `userService` injected into `AuthViewModel` but never used. (`AuthFeature.swift` L18–26)
- `MemoryDatabaseStore` continuation cleanup uses `Task { await self.removeContinuation }` — small race window. (`Services/BackendServices.swift` L77–79)
- `Shared/Components/AsyncStateView.swift` and `LoadableState` are defined but **no feature uses them** — features show inline `ProgressView` instead.
- `DesignSystem` — minor accessibility risks (white CTA text on gradient, fixed icon sizes in `EmptyStateView`).
- `Shared/Helpers/Formatters.swift` is unreferenced.
- No `.github/` or other CI configuration.
- Mixed feature structure: most features are `View + ViewModel` in one file, but some directories still have `ViewModels/` subfolders.

---

## 2. Build Status (per area)


| Area                                          | Status                                                  | Notes                                                                                                                                               |
| --------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| App bootstrap & DI                            | **Partial**                                             | Works, but uses singletons + post-init mutation; order-dependent.                                                                                   |
| Auth — Firebase email + Apple + Google        | **Partial / works when SDKs + plist + secrets present** | Without `GoogleService-Info.plist`: degrades to local Keychain auth (insecure SHA256). Without `GoogleSignIn` SDK: returns hard-coded demo profile. |
| Onboarding flow                               | **Partial**                                             | Works end-to-end; retry / loading guards weak; calendar/syllabus not required to finish onboarding.                                                 |
| Paywall flow                                  | **Partial**                                             | Real RC purchase/restore when SDK + key present; **not** linked to Firebase user; user can be stuck on paywall on misconfig.                        |
| Today                                         | **Partial**                                             | Real planner/check-ins/habits/AI vibe; shared mood state, single error channel.                                                                     |
| Goals                                         | **Partial**                                             | CRUD + plan generation real and persisted; reorder races; plan generation lockout is global.                                                        |
| Calendar                                      | **Partial**                                             | EventKit import + reconciliation real; week/day timeline brittle layout.                                                                            |
| Sessions                                      | **Partial**                                             | Real save/complete/cancel/delete + local notification; battery and a11y issues.                                                                     |
| Reflections                                   | **Partial**                                             | Real CRUD + AI vibe; missing dedup vs Today; no in-flight guards.                                                                                   |
| Imports                                       | **Partial**                                             | Real text/file flow with PDFKit fallback; no commit guard; cloud has `undefined` doc bug.                                                           |
| Settings                                      | **Partial**                                             | All buttons real; profile editor dismisses before save (Critical).                                                                                  |
| Assistant                                     | **Partial**                                             | Cloud + local; commit-draft semantics differ between client and server.                                                                             |
| Persistence — local JSON                      | **Built**                                               | File-backed, throws on disk failure (recent fix).                                                                                                   |
| Persistence — Firestore                       | **Conditional / blocked**                               | Allowed user collections work; AI/import/plan collections **forbidden by rules** but written by client local fallbacks.                             |
| Networking                                    | **Built**                                               | Firebase ID token injection, retry policy correct (no 4xx/decode retry).                                                                            |
| Notifications — local                         | **Built**                                               | UNUserNotificationCenter + per-session timers.                                                                                                      |
| Notifications — push (token)                  | **Partial**                                             | Token persisted to user profile when user is signed in at the moment the token arrives. No retry if not.                                            |
| Notifications — push (server fan-out)         | **Missing / dead code**                                 | `dispatch.ts` not exported. No senders.                                                                                                             |
| Cloud Functions — assistant                   | **Built**                                               | JSON contract matches client (`{thread}` from `assistantRespond`); commit-draft writes Firestore.                                                   |
| Cloud Functions — syllabus                    | **Mostly built**                                        | Real AI parse + fallback; `String(course.id ?? undefined)` bug (Critical).                                                                          |
| Cloud Functions — billing webhook             | **Partial**                                             | Real Firestore writes; webhook auth optional via env (Critical).                                                                                    |
| Cloud Functions — data jobs (export / delete) | **Built**                                               | Real account deletion + export.                                                                                                                     |
| AI provider                                   | **Stub default**                                        | Defaults to `StubProvider` unless `AI_*` env vars are set.                                                                                          |
| Firestore rules                               | **Partial**                                             | Reasonable for user-owned data; misaligned with what the iOS client tries to write.                                                                 |
| Storage rules                                 | **Built**                                               | Owner-only, 10MB cap, MIME constraints.                                                                                                             |
| iOS project / signing / capabilities          | **Missing**                                             | No entitlements, no privacy manifest, no real `GoogleService-Info.plist`, no real Secrets.xcconfig.                                                 |
| Tests                                         | **Partial**                                             | Unit tests exercise services with fresh DB; no tests for app gating, container wiring, paywall, or RC.                                              |
| CI                                            | **Missing**                                             | No CI config in repo.                                                                                                                               |


---

## 3. Next Development Work

### Core functionality

1. Decide a single **server-of-record policy** for `assistantThreads`, `goalPlans`, `imports`, `subscriptions`, `aiUsageLogs`, `assistantDraftArtifacts`. Either:
  - **All writes go through Cloud Functions** (delete client local-fallback writes), or
  - **Relax rules with strict server-side validators** (only specific shapes allowed).
2. Tie **RevenueCat to Firebase user** (`Purchases.logIn`/`logOut`) on auth state changes.
3. Wire `pendingRoute` to fire on `AppShellView.onAppear` so cold-start deep links are not lost.
4. Make `ProfileEditorSheet` await the save before dismissing.
5. Surface subscription refresh failure to the user (retry / support) instead of silent lock on paywall.
6. Add server-side push: export `dispatch.ts`, add Firestore triggers (`onCreate` of `plannerBlocks` due soon, `goalPlans` ready, etc.) that call `dispatch.send(...)`.
7. Fix `commitImportJob` doc id in `syllabus.ts`.

### Data flow / state

1. Cancel sibling tasks in `PlannerService.observeSnapshot` on first error.
2. Apply duplicate-check-in rule in `ReflectionsViewModel.saveCheckIn` (parity with Today).
3. Add in-flight guards to `Reflections.saveVibeCheck`, `Imports.commit`, `Goals.move`.
4. Fix Today’s shared `selectedMood` — separate state for check-in mood and vibe mood.
5. Per-stream `errorMessage` (or a stack) in Today instead of one shared field.
6. `OnboardingViewModel.load()` should always allow retry; add `isLoading` guard to `importSyllabus`.

### Auth

1. Remove or harden the non-Firebase email/password path (PBKDF2/Argon2 + salt, server-side verification) before any prod build.
2. Remove the hard-coded Google demo profile or at least gate it to `#if DEBUG`.

### Paywall / Subscriptions

1. Use **server-authoritative subscription read** (Firestore `users/{uid}/subscriptions/active` doc updated by webhook) as the source of truth in the iOS client; treat RevenueCat as an SDK that triggers the webhook, not the source of truth.
2. Make RC StoreKit products + offerings + entitlements identifiers explicit in code (don’t infer from product name “contains month”).

### Calendar / Sessions

1. Replace fixed-height day timeline with adaptive layout (LazyVStack + per-block layout); test on iPad & large Dynamic Type.
2. Make Sessions timer a per-session timer driven by an active session’s state, not a global 1 Hz publisher.
3. Use `Font.system(.largeTitle, design: .rounded)` (or scaled font) for the session timer.

### Onboarding / Settings / Imports

1. Decide whether calendar/syllabus import is required for onboarding; reflect that in `OnboardingState.isComplete`.
2. Keep child views in Settings using the live `viewModel.profile` (already done) — verify no other place re-uses the stale `init` user.
3. Show commit progress for Imports; lock the row while committing.

### Assistant

1. Use `request.action.id` in client local-fallback `commitAssistantDraft` so server and client agree on artifact identity.
2. Pull RC entitlement check before allowing assistant message send if assistant is paywalled.

### Tests

1. Add tests for: gating logic (`AppSessionViewModel`), `AppContainer.live()` wiring, RevenueCat flow with stub, Firestore rules (using emulator), syllabus commit doc id.

### Project / Configuration

1. Reconcile `IPHONEOS_DEPLOYMENT_TARGET` (project vs target).
2. Add `aicalendarapp.entitlements`: `aps-environment`, `com.apple.developer.applesignin`.
3. Add `PrivacyInfo.xcprivacy`.
4. Add app icons (verify all sizes), launch screen polish.
5. Add CI (build + tests + lint Swift; build + lint TS).

---

## 4. Non-Code Blockers

For each: **what**, **why**, **when it blocks**.

### Required for full development today

- **LLM API key + endpoint (`AI_API_KEY`, `AI_ENDPOINT`, `AI_PROVIDER`)** — without it the backend uses the `StubProvider`. Blocks meaningful AI testing now.
- **Firebase project + real `GoogleService-Info.plist`** — without it, all of Firebase Auth/Firestore/Storage/FCM/Analytics are skipped and the app uses local-only paths. Blocks real auth + cloud testing now.
- `**API_BASE_URL` for deployed Cloud Functions** — without it, `BackendFunctionService.invoke` returns nil and falls back to local generators; you cannot test real assistant/import flows. Blocks now.
- `**Secrets.xcconfig` filled** (`API_BASE_URL`, `REVENUECAT_API_KEY`, `SUPERWALL_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`, `APP_URL_SCHEME`) — driven from `Secrets.template.xcconfig`. Without it, builds compile but Google sign-in / RC / Superwall are no-ops. Blocks Google + RC + Superwall testing now.
- `**.firebaserc`** copied from template with real project ID — needed to deploy backend. Blocks backend deploy now.
- **Firebase Cloud Functions deployed** (`firebase deploy --only functions`) — without deploy, no `API_BASE_URL` is reachable.
- **RevenueCat account + iOS SDK key + offerings/products/entitlements configured** — without it, the paywall is purely local. Blocks paywall testing now.
- **App Store Connect: in-app purchase products (monthly + annual + free trial)** — required to test RevenueCat purchases on TestFlight devices. Blocks IAP testing soon.
- **REVENUECAT_WEBHOOK_SECRET** in Firebase Functions config — without it, the webhook is open. Blocks safe production webhook now.

### Required before TestFlight / external beta

- **Apple Developer account** — required to sign builds, enable Push, Sign in with Apple, App Store distribution.
- **Push notification capability + APNs key/cert** — required for FCM-driven push.
- **Sign in with Apple capability** in Apple Developer portal + entitlements file.
- **Google OAuth client ID** in Google Cloud Console + the reversed client ID URL scheme in `Info.plist`.
- **Superwall account + API key** (only if Superwall paywalls are part of launch).
- **App icons set complete + launch screen reviewed** (required to pass App Store review).
- **TestFlight setup**: app record in App Store Connect, internal/external testing groups.

### Required before public launch (App Store)

- **Privacy policy URL + Terms of Service URL** (App Store metadata).
- **App Privacy questionnaire** in App Store Connect.
- `**PrivacyInfo.xcprivacy`** declaring required reason APIs and tracking domains for Firebase / RevenueCat / GoogleSignIn.
- **Account deletion path** in-app and on a public web URL (Apple requires deletion to be reachable from app and from outside the app).
- **App Store screenshots, description, keywords, support URL.**
- **Crash reporting + analytics opt-in/out** if marketing requires it.
- **EU compliance**: DSA contact, possibly GDPR data processing addendum with Firebase / RevenueCat.

### Operational (production)

- **Monitoring / alerting** for Cloud Functions (Cloud Monitoring + uptime + error budget).
- **Cost guardrails** for the LLM (per-user and global rate limits — partially in `aiUsageLogs`).
- **Backup policy** for Firestore.

---

## 5. Prioritization

### Fix Now (code)

- C1 — Resolve the Firestore-rules ↔ client-write mismatch (architecture decision + code change).
- C2 — Settings profile save: await before dismiss.
- C3 — Apply `pendingRoute` on `AppShellView.onAppear`.
- C4 — `Purchases.logIn`/`logOut` aliasing to Firebase UID.
- C5 — Refuse to start `revenuecat` webhook function without secret.
- C6 — Export `dispatch.ts` and wire at least one trigger (or remove dead code).
- C7 — Surface subscription refresh failure (no silent paywall lock).
- C8 — `commitImportJob` doc id (server bug).
- C9 — `PlannerService` cancel siblings on first error.
- C12 — Reflections duplicate check-in dedup.

### Build Next (after Fix Now)

- I1 (deployment target reconciliation), I8 (goals reorder serialization), I13–I15 (in-flight guards in Reflections / Imports / Goals plan generation), I5–I6 (Today shared state), I9–I11 (Sessions), I12 (Calendar timeline layout), I20 (assistant action id), I21 (clarify onboarding completion rule), I16 (storage durable fallback or fail loudly).
- Then move to: server-authoritative subscription read in client, more granular AI rate limit / paywall enforcement, push notification fan-out for actual events.

### Non-code setup needed now (to unblock real dev)

- LLM provider account + key/endpoint (set `AI_`* env on Firebase Functions).
- Firebase project + add `GoogleService-Info.plist` to the iOS app.
- Copy `.firebaserc.template` → `.firebaserc` with real project ID.
- Copy `Secrets.template.xcconfig` → `Secrets.xcconfig` and fill at least `API_BASE_URL`, `APP_URL_SCHEME`.
- Deploy Cloud Functions (`firebase deploy --only functions`) so the iOS client has a real `API_BASE_URL`.
- Firestore rules + indexes deploy (`firebase deploy --only firestore`); Storage rules deploy.
- Set `REVENUECAT_WEBHOOK_SECRET` in Firebase Functions runtime config.
- RevenueCat account + iOS SDK key + Offerings + products in App Store Connect (sandbox testing).

### Non-code setup needed later (before beta / launch)

- Apple Developer membership + provisioning profile + signing.
- Push notification capability + APNs key.
- Sign in with Apple capability + entitlements file.
- Google OAuth client + reversed client ID into `Info.plist`.
- Superwall account (only if used at launch).
- TestFlight app record + testers.
- Privacy policy + ToS URLs.
- `PrivacyInfo.xcprivacy` (committed to repo, configured per SDK).
- App Privacy questionnaire in App Store Connect.
- App Store metadata (screenshots, copy, support URL, account deletion URL).
- Cost / alerting guardrails for backend + LLM.

---

## Appendix A — “Looks done, isn’t” pitfalls to call out to the team

1. **Goal plans, assistant threads, syllabus jobs**: writing to Firestore from the client **will fail** with rules deployed. The local fallback hides this when Firebase isn’t configured.
2. **Google sign-in** without the SDK present silently signs you in as a hard-coded demo user.
3. **Email/password without Firebase** is local-only with SHA256-hashed Keychain entries — it is not “sign-in”.
4. **Paywall** seems to allow purchase/restore without RC, because the no-RC branch fabricates an active subscription.
5. **Server cannot send push** — the FCM dispatch function is implemented but unwired.
6. **AI is a stub by default** — without `AI_`* env, you’re reading echo-flavored text from `StubProvider`.
7. **Subscription state lives in RevenueCat + memory only on device** — the Firestore subscription doc updated by the webhook is not read by the client.

---

## Appendix B — Files audited (high-signal)

- App: `App/Bootstrap/aicalendarappApp.swift`, `App/Bootstrap/AppDelegate.swift`, `App/DependencyInjection/AppContainer.swift`, `App/Navigation/AppRootFeature.swift`
- Core: `Core/Models/AppModels.swift`, `Core/Models/BackendFunctionModels.swift`, `Core/Protocols/ServiceProtocols.swift`, `Core/Persistence/KeychainStore.swift`, `Core/Networking/APIEndpoint.swift`, `Core/Utilities/AppConfiguration.swift`, `Core/Extensions/CodingExtensions.swift`, `Core/Errors/AppError.swift`, `Core/Logging/AppLogger.swift`
- Services: `Services/BackendServices.swift`, `Services/FeatureServices.swift`, `Services/MonetizationServices.swift`, `Services/SystemServices.swift`, `Services/AI/BackendFunctionService.swift`, `Services/Backend/NetworkService.swift`
- Features: Auth, Onboarding, Today, Goals, Calendar, Sessions, Settings, Reflections, Imports, Paywall, Shell
- Backend: `backend/functions/src/{ai/assistant.ts, ai/prompts.ts, ai/provider.ts, billing/revenuecat.ts, imports/syllabus.ts, notifications/dispatch.ts, shared/{http.ts,context.ts,contracts.ts,firestore.ts}, users/dataJobs.ts, index.ts}`
- Rules: `backend/firestore/firestore.rules`, `backend/storage/storage.rules`
- Project: `firebase.json`, `aicalendarapp.xcodeproj/project.pbxproj`, `Config/Info.plist`, `Resources/Config/{Debug.xcconfig, Release.xcconfig, Secrets.template.xcconfig, GoogleService-Info.plist.template}`, `Package.swift`, `scripts/bootstrap_backend.sh`
- Tests: `aicalendarappTests/Unit/aicalendarappTests.swift`, `aicalendarappUITests/UI/*.swift`
