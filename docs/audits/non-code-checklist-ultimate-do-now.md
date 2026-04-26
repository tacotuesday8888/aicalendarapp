# Ultimate Do-Now Non-Code Checklist

Purpose: this is the single source of truth for every required **sign-up + non-code task** you must complete now so development can continue without external blockers.

---

## 1) Create / confirm Apple Developer access

- **Task**
  - Create (or confirm active) Apple Developer Program access with App Store Connect permissions.
- **Type**: Sign-Up
- **Service / Platform**
  - Apple Developer Program
  - App Store Connect
- **Why it is needed**
  - Required for iOS app identity, Sign in with Apple, APNs push setup, and App Store subscription products.
- **Where to do it**
  - Apple Developer website
  - App Store Connect
- **How to do it (step-by-step)**
  1. Sign in with your Apple ID.
  2. Enroll in Apple Developer Program if not already enrolled.
  3. Complete organization/individual verification and payment.
  4. Confirm you can open App Store Connect with admin-level access.
  5. Confirm access to Certificates, Identifiers, and Keys in Apple Developer.
- **Direct link(s)**
  - [Apple Developer Program](https://developer.apple.com/programs/)
  - [Apple Developer Account](https://developer.apple.com/account/)
  - [App Store Connect](https://appstoreconnect.apple.com/)
- **What I should prepare beforehand**
  - Apple ID with 2FA
  - Legal entity details (if organization account)
  - Payment method for annual membership
- **What this unlocks for you**
  - I can proceed with real Apple auth/push/subscription integration validation.
- **Blocking**: Yes

---

## 2) Create / confirm Firebase account and create the real project

- **Task**
  - Create the production-intended Firebase project and connect this repo to it.
- **Type**: Sign-Up
- **Service / Platform**
  - Firebase (Google Cloud)
- **Why it is needed**
  - The app/backend needs real Firebase Auth, Firestore, Storage, Functions, and Messaging.
- **Where to do it**
  - Firebase Console
  - Local terminal (Firebase CLI login)
  - Repo file: `aicalendarapp/.firebaserc`
- **How to do it (step-by-step)**
  1. Sign in to Firebase Console with your Google account.
  2. Create a new Firebase project with a stable project id.
  3. Enable billing plan needed for Cloud Functions usage (Blaze).
  4. Run `firebase login` in terminal.
  5. Copy `aicalendarapp/.firebaserc.template` to `aicalendarapp/.firebaserc`.
  6. Replace placeholder ids in `.firebaserc` with your real project id.
  7. Keep `default` set to the dev project you want to use first.
- **Direct link(s)**
  - [Firebase Console](https://console.firebase.google.com/)
  - [Firebase CLI docs](https://firebase.google.com/docs/cli)
  - [Google Cloud Billing](https://console.cloud.google.com/billing)
- **What I should prepare beforehand**
  - Google account with project creation permissions
  - Project name/id decision
  - Billing-enabled payment method
- **What this unlocks for you**
  - I can use/deploy the real backend stack and verify live data/auth flows.
- **Blocking**: Yes

---

## 3) Register the iOS app in Firebase and add `GoogleService-Info.plist`

- **Task**
  - Add iOS app `com.langqi.aicalendarapp` in Firebase and include the real plist in the app target.
- **Type**: Setup
- **Service / Platform**
  - Firebase iOS app registration
- **Why it is needed**
  - Firebase init is skipped when `GoogleService-Info.plist` is missing; app remains in fallback mode.
- **Where to do it**
  - Firebase Console -> Project Settings
  - Xcode / Finder
  - Target path: `aicalendarapp/aicalendarapp/`
- **How to do it (step-by-step)**
  1. Open Firebase Project Settings.
  2. Under "Your apps", add an iOS app.
  3. Enter bundle id: `com.langqi.aicalendarapp`.
  4. Download `GoogleService-Info.plist`.
  5. Drag file into Xcode project under app target.
  6. Ensure the app target checkbox is selected in "Add Files".
  7. Confirm exact filename is `GoogleService-Info.plist`.
- **Direct link(s)**
  - [Firebase Project Settings](https://console.firebase.google.com/project/_/settings/general/)
- **What I should prepare beforehand**
  - Firebase project created
  - Correct iOS bundle id
- **What this unlocks for you**
  - I can validate real Firebase initialization and iOS Firebase SDK connectivity.
- **Blocking**: Yes

---

## 4) Enable required Firebase products and providers

- **Task**
  - Enable all Firebase services currently expected by the app and backend.
- **Type**: Configuration
- **Service / Platform**
  - Firebase Authentication, Firestore, Storage, Cloud Messaging, Cloud Functions
- **Why it is needed**
  - Features will fail or remain untestable unless these services/providers are active.
- **Where to do it**
  - Firebase Console
- **How to do it (step-by-step)**
  1. In Authentication -> Sign-in methods, enable:
    - Email/Password
    - Google
    - Apple
  2. In Firestore, create database in your intended region.
  3. In Storage, enable Firebase Storage.
  4. In Cloud Messaging, open settings and verify project readiness.
  5. Confirm project permissions/billing are sufficient for Functions deploy/runtime.
- **Direct link(s)**
  - [Firebase Auth Providers](https://console.firebase.google.com/project/_/authentication/providers)
  - [Firestore](https://console.firebase.google.com/project/_/firestore)
  - [Storage](https://console.firebase.google.com/project/_/storage)
  - [Cloud Messaging](https://console.firebase.google.com/project/_/settings/cloudmessaging)
- **What I should prepare beforehand**
  - Firebase project id
  - Region decision for data/functions
- **What this unlocks for you**
  - I can run true auth/data/file workflows and continue integration hardening.
- **Blocking**: Yes

---

## 5) Create RevenueCat account and project

- **Task**
  - Create RevenueCat account and initialize the iOS app/project there.
- **Type**: Sign-Up
- **Service / Platform**
  - RevenueCat
- **Why it is needed**
  - Subscription/paywall flow depends on RevenueCat SDK config and webhook sync.
- **Where to do it**
  - RevenueCat dashboard
- **How to do it (step-by-step)**
  1. Sign up/login to RevenueCat.
  2. Create a RevenueCat project for this app.
  3. Add iOS app with bundle id `com.langqi.aicalendarapp`.
  4. Keep dashboard open for key/product/offering setup in next tasks.
- **Direct link(s)**
  - [RevenueCat Dashboard](https://app.revenuecat.com/)
- **What I should prepare beforehand**
  - App name and bundle id
  - Admin access to billing owner account
- **What this unlocks for you**
  - I can complete real paywall/subscription integration verification.
- **Blocking**: Yes

---

## 6) Create App Store subscription products and map them in RevenueCat

- **Task**
  - Create iOS subscriptions in App Store Connect and wire entitlement/offering/products in RevenueCat.
- **Type**: Configuration
- **Service / Platform**
  - App Store Connect + RevenueCat
- **Why it is needed**
  - Without real products/entitlements, purchase/restore and access gating cannot be tested correctly.
- **Where to do it**
  - App Store Connect
  - RevenueCat Dashboard
- **How to do it (step-by-step)**
  1. In App Store Connect, create subscription group and products (monthly/annual as planned).
  2. In RevenueCat, create entitlement (for premium access).
  3. Create offering and attach packages to your App Store products.
  4. Copy RevenueCat iOS Public SDK Key for app config task.
  5. Record exact product ids for consistency across environments.
- **Direct link(s)**
  - [App Store Connect](https://appstoreconnect.apple.com/)
  - [RevenueCat Entitlements Guide](https://www.revenuecat.com/docs/getting-started/entitlements)
- **What I should prepare beforehand**
  - Apple Developer/App Store Connect access
  - RevenueCat project created
  - Product naming/price plan
- **What this unlocks for you**
  - I can validate real purchases, restores, and entitlement gating.
- **Blocking**: Yes

---

## 7) Create AI provider account and API key

- **Task**
  - Create an account with one OpenAI-compatible provider and generate a production-ready API key.
- **Type**: Sign-Up
- **Service / Platform**
  - OpenAI-compatible LLM provider (e.g., OpenAI or OpenRouter)
- **Why it is needed**
  - Assistant, goal plan generation, and syllabus parsing need live backend AI credentials.
- **Where to do it**
  - Provider dashboard
- **How to do it (step-by-step)**
  1. Sign up for your chosen provider.
  2. Enable billing/payment.
  3. Create API key.
  4. Choose model name and endpoint for backend config.
  5. Store the key securely (password manager/secret vault).
- **Direct link(s)**
  - [OpenAI API Keys](https://platform.openai.com/api-keys)
  - [OpenAI API Docs](https://platform.openai.com/docs/api-reference)
  - [OpenRouter Keys](https://openrouter.ai/keys)
- **What I should prepare beforehand**
  - Decision on provider
  - Billing method
  - Model/cost preference
- **What this unlocks for you**
  - I can validate real AI-backed backend endpoints instead of stubs.
- **Blocking**: Yes

---

## 8) Configure iOS runtime app config values (`Debug.xcconfig` and `Release.xcconfig`)

- **Task**
  - Fill all required runtime config keys used by the iOS app.
- **Type**: Configuration
- **Service / Platform**
  - Xcode project config (`.xcconfig`)
- **Why it is needed**
  - App runtime values for backend URL, auth, and subscription SDK are read from these files.
- **Where to do it**
  - `aicalendarapp/aicalendarapp/Resources/Config/Debug.xcconfig`
  - `aicalendarapp/aicalendarapp/Resources/Config/Release.xcconfig`
  - Template: `aicalendarapp/aicalendarapp/Resources/Config/Secrets.template.xcconfig`
- **How to do it (step-by-step)**
  1. Open both Debug and Release xcconfig files.
  2. Set:
    - `API_BASE_URL` (Functions URL root)
    - `REVENUECAT_API_KEY` (from RevenueCat)
    - `GOOGLE_CLIENT_ID` (from Firebase plist)
    - `GOOGLE_REVERSED_CLIENT_ID` (from Firebase plist)
  3. Ensure `APP_URL_SCHEME = aicalendarapp` stays consistent unless intentionally changing globally.
  4. Save both files with matching environment-appropriate values.
- **Direct link(s)**
  - [Firebase Functions URL pattern reference](https://firebase.google.com/docs/functions/http-events)
- **What I should prepare beforehand**
  - Firebase project id
  - `GoogleService-Info.plist`
  - RevenueCat iOS Public SDK key
- **What this unlocks for you**
  - I can test live API calls and real provider-backed app runtime behavior.
- **Blocking**: Yes

---

## 9) Configure backend runtime secrets (AI + webhook + project id)

- **Task**
  - Set the required backend environment secrets used by Functions.
- **Type**: Configuration
- **Service / Platform**
  - Firebase Functions runtime secrets / env management
- **Why it is needed**
  - Missing secrets forces stub AI behavior and blocks secure webhook processing.
- **Where to do it**
  - Your Functions secret/env workflow
  - Reference: `aicalendarapp/backend/config/.env.example`
- **How to do it (step-by-step)**
  1. Open `.env.example` and list required values:
    - `AI_PROVIDER`
    - `AI_MODEL`
    - `AI_ENDPOINT`
    - `AI_API_KEY`
    - `REVENUECAT_WEBHOOK_SECRET`
    - `FIREBASE_PROJECT_ID`
  2. Generate a strong random `REVENUECAT_WEBHOOK_SECRET`.
  3. Set all values in your actual deploy/runtime secret mechanism.
  4. Ensure `FIREBASE_PROJECT_ID` matches your real Firebase project id exactly.
- **Direct link(s)**
  - [Firebase Functions config/secrets](https://firebase.google.com/docs/functions/config-env)
  - [RevenueCat Webhooks](https://www.revenuecat.com/docs/integrations/webhooks)
- **What I should prepare beforehand**
  - AI provider account + key
  - Firebase project id
  - Secure secret storage method
- **What this unlocks for you**
  - I can validate real AI workflows and secure billing webhook behavior.
- **Blocking**: Yes

---

## 10) Configure RevenueCat webhook to Firebase function

- **Task**
  - Point RevenueCat webhook to your Firebase endpoint with the shared secret.
- **Type**: Configuration
- **Service / Platform**
  - RevenueCat Webhooks + Firebase Functions
- **Why it is needed**
  - Backend subscription state sync depends on webhook delivery and verification.
- **Where to do it**
  - RevenueCat dashboard webhook settings
- **How to do it (step-by-step)**
  1. Build webhook URL:
    - `https://us-central1-<YOUR_PROJECT_ID>.cloudfunctions.net/revenueCatWebhook`
  2. In RevenueCat, create/edit webhook endpoint with that URL.
  3. Set authorization header/secret to exactly `REVENUECAT_WEBHOOK_SECRET`.
  4. Save and send a test event from RevenueCat.
  5. Confirm event reaches backend (from console logs/monitoring on your side).
- **Direct link(s)**
  - [RevenueCat Webhooks](https://www.revenuecat.com/docs/integrations/webhooks)
- **What I should prepare beforehand**
  - Firebase project id
  - RevenueCat webhook secret already set in backend
- **What this unlocks for you**
  - I can verify end-to-end billing lifecycle updates in-app.
- **Blocking**: Yes

---

## 11) Complete Apple Sign-In and Google Sign-In provider-side setup

- **Task**
  - Finalize provider setup in Apple Developer and Firebase Auth for live sign-in tests.
- **Type**: Configuration
- **Service / Platform**
  - Apple Developer + Firebase Authentication
- **Why it is needed**
  - App UI exists, but real provider auth cannot be validated without console-side setup.
- **Where to do it**
  - Apple Developer (Identifiers / Keys)
  - Firebase Auth Providers
- **How to do it (step-by-step)**
  1. In Firebase Auth Providers, verify Google is enabled and configured.
  2. In Apple Developer, ensure app id has Sign in with Apple capability.
  3. Create Apple auth key/identifiers required by Firebase.
  4. In Firebase Auth Providers, enable Apple and enter required Apple values.
  5. Confirm everything maps to bundle id `com.langqi.aicalendarapp`.
- **Direct link(s)**
  - [Firebase Auth Providers](https://console.firebase.google.com/project/_/authentication/providers)
  - [Apple Identifiers](https://developer.apple.com/account/resources/identifiers/list)
  - [Apple Keys](https://developer.apple.com/account/resources/authkeys/list)
- **What I should prepare beforehand**
  - Firebase project ready
  - Apple Developer access
  - Correct bundle id
- **What this unlocks for you**
  - I can run true Apple/Google login validation and auth flow hardening.
- **Blocking**: Yes

---

## 12) Configure APNs key and link it to Firebase Cloud Messaging

- **Task**
  - Create APNs Auth Key and connect it to Firebase Cloud Messaging.
- **Type**: Configuration
- **Service / Platform**
  - Apple Push Notification service (APNs) + Firebase Cloud Messaging
- **Why it is needed**
  - Push trigger code exists, but end-to-end push cannot work until APNs is linked.
- **Where to do it**
  - Apple Developer -> Keys
  - Firebase Console -> Cloud Messaging settings
- **How to do it (step-by-step)**
  1. In Apple Developer, create APNs Auth Key.
  2. Download `.p8` key and store securely (download is one-time).
  3. Collect Key ID and Team ID from Apple Developer.
  4. In Firebase Cloud Messaging settings, upload APNs key and fill Key ID + Team ID.
  5. Confirm Push Notifications capability is enabled for app id.
- **Direct link(s)**
  - [Apple Keys](https://developer.apple.com/account/resources/authkeys/list)
  - [Firebase Cloud Messaging Settings](https://console.firebase.google.com/project/_/settings/cloudmessaging)
- **What I should prepare beforehand**
  - Apple Developer access
  - Existing app id for `com.langqi.aicalendarapp`
- **What this unlocks for you**
  - I can validate real device push notification delivery paths.
- **Blocking**: Yes

---

## Completion handoff (send these back to me)

After finishing the checklist, send:

1. Firebase project id
2. Confirmation `GoogleService-Info.plist` is added to app target
3. Final `API_BASE_URL` value
4. Confirmation `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` are filled
5. Confirmation `REVENUECAT_API_KEY` is filled
6. Confirmation AI env vars are set
7. Confirmation `REVENUECAT_WEBHOOK_SECRET` is set in backend and RevenueCat
8. Confirmation Apple + Google providers are enabled in Firebase Auth
9. Confirmation APNs is linked in Firebase Cloud Messaging
