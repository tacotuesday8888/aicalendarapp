# Non-Code Checklist — Do Now

> Purpose: these are the **exact non-code tasks you need to complete now** so I can continue effective development and live integration work.
>
> Scope: only things **you** must do because they require your accounts, keys, console access, or manual platform setup.

---

## 1. Create and connect the real Firebase project

- **Task**
  - Create the real Firebase project for this app and connect this local repo to it.
- **Why it is needed**
  - Right now the app drops to local-only adapters when Firebase is missing.
  - Without a real project, I cannot verify live auth, Firestore, Storage, Functions, or Messaging.
- **Where to do it**
  - Firebase Console
  - Your local terminal
  - Repo file: `aicalendarapp/.firebaserc`
- **How to do it**
  1. Go to Firebase Console and create a new project.
  2. Choose a project id you want to keep long-term.
  3. On this machine, log in to Firebase CLI:
    ```bash
     firebase login
    ```
  4. In the repo, copy:
    ```bash
     cp aicalendarapp/.firebaserc.template aicalendarapp/.firebaserc
    ```
  5. Replace the placeholder ids in `.firebaserc` with your real Firebase project id.
  6. Keep the `default` project pointing at the dev project you want us to use first.
- **Direct link(s)**
  - [Firebase Console](https://console.firebase.google.com/)
  - [Firebase CLI setup](https://firebase.google.com/docs/cli)
- **What you should prepare beforehand**
  - A Google account with permission to create Firebase projects
  - The project name/id you want to use for development
- **What this unlocks for me once completed**
  - I can deploy Functions/rules
  - I can connect the app to real Firebase services
  - I can verify live backend-only flows
- **Blocks**
  - **Development**

---

## 2. Register the iOS app in Firebase and add the real `GoogleService-Info.plist`

- **Task**
  - Add the iOS app (`com.langqi.aicalendarapp`) to the Firebase project and place the real `GoogleService-Info.plist` into the app target.
- **Why it is needed**
  - `AppDelegate` explicitly skips Firebase setup when `GoogleService-Info.plist` is missing.
  - Without it, the app stays in local fallback mode.
- **Where to do it**
  - Firebase Console → Project Settings
  - Xcode / Finder
  - App target path: `aicalendarapp/aicalendarapp/`
- **How to do it**
  1. In Firebase Console, open **Project settings**.
  2. Under **Your apps**, add an **iOS app**.
  3. Use bundle id:
    - `com.langqi.aicalendarapp`
  4. Download `GoogleService-Info.plist`.
  5. Drag it into the `aicalendarapp` app target in Xcode.
  6. Make sure the **app target is checked** in the “Add Files” dialog.
  7. Confirm the file is named exactly:
    - `GoogleService-Info.plist`
- **Direct link(s)**
  - [Firebase Project Settings](https://console.firebase.google.com/project/_/settings/general/)
- **What you should prepare beforehand**
  - Step 1 completed
  - The bundle id above
- **What this unlocks for me once completed**
  - Live Firebase initialization on device/simulator
  - Real Firebase Auth / Firestore / Storage / Messaging usage
- **Blocks**
  - **Development / Testing**

---

## 3. Enable the Firebase products this app already expects

- **Task**
  - Turn on the Firebase services the code already uses.
- **Why it is needed**
  - The code expects Auth, Firestore, Storage, Cloud Messaging, and Functions to exist.
  - If these are off, live development stalls or silently falls back.
- **Where to do it**
  - Firebase Console
- **How to do it**
  1. **Authentication**
    - Enable **Email/Password**
    - Enable **Google**
    - Enable **Apple**
  2. **Firestore Database**
    - Create the database
    - Use your preferred region (pick the one you plan to keep)
  3. **Storage**
    - Enable Firebase Storage
  4. **Cloud Messaging**
    - Open Cloud Messaging settings so the project is ready for APNs linking later
  5. **Cloud Functions**
    - Make sure billing/project permissions are sufficient for deploying Functions
- **Direct link(s)**
  - [Firebase Auth Providers](https://console.firebase.google.com/project/_/authentication/providers)
  - [Firestore](https://console.firebase.google.com/project/_/firestore)
  - [Storage](https://console.firebase.google.com/project/_/storage)
  - [Cloud Messaging settings](https://console.firebase.google.com/project/_/settings/cloudmessaging)
- **What you should prepare beforehand**
  - Step 1 complete
  - Decide your Firebase region (Firestore/Functions)
- **What this unlocks for me once completed**
  - Real auth and data testing
  - Real file uploads
  - Push setup can be finished later without redoing project creation
- **Blocks**
  - **Development / Testing**

---

## 4. Fill the live app config values in the iOS xcconfig files

- **Task**
  - Put the real values into the active iOS config files.
- **Why it is needed**
  - `Info.plist` reads these values at runtime.
  - Without them, backend calls, RevenueCat, and Google sign-in are not real.
- **Where to do it**
  - Repo files:
    - `aicalendarapp/aicalendarapp/Resources/Config/Debug.xcconfig`
    - `aicalendarapp/aicalendarapp/Resources/Config/Release.xcconfig`
  - Reference template:
    - `aicalendarapp/aicalendarapp/Resources/Config/Secrets.template.xcconfig`
- **How to do it**
  1. Open both `Debug.xcconfig` and `Release.xcconfig`.
  2. Fill these values:
    - `API_BASE_URL`
    - `REVENUECAT_API_KEY`
    - `GOOGLE_CLIENT_ID`
    - `GOOGLE_REVERSED_CLIENT_ID`
  3. Optional for now:
    - `SUPERWALL_API_KEY` (only if you want Superwall active right away)
  4. Keep:
    - `APP_URL_SCHEME = aicalendarapp` as-is unless you want to change it everywhere.
  5. Set `API_BASE_URL` to your Functions root, for example:
    - `https://us-central1-<YOUR_PROJECT_ID>.cloudfunctions.net/`
  6. The easiest source for `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` is your downloaded `GoogleService-Info.plist`.
- **Direct link(s)**
  - Project file using these values: `aicalendarapp/Config/Info.plist`
- **What you should prepare beforehand**
  - Firebase project id
  - `GoogleService-Info.plist`
  - RevenueCat iOS public SDK key
- **What this unlocks for me once completed**
  - Live backend calls from the iOS app
  - Google sign-in wiring
  - Truthful paywall setup
- **Blocks**
  - **Development / Testing**

---

## 5. Configure the backend runtime secrets for AI + webhook security

- **Task**
  - Provide the backend environment/secrets the Functions code actually needs.
- **Why it is needed**
  - Without AI credentials, the backend uses the stub provider.
  - Without the webhook secret, RevenueCat webhook processing is intentionally refused.
- **Where to do it**
  - Your backend/deployment secret flow
  - Reference file:
    - `aicalendarapp/backend/config/.env.example`
- **How to do it**
  1. Open:
    - `aicalendarapp/backend/config/.env.example`
  2. Prepare real values for:
    - `AI_PROVIDER`
    - `AI_MODEL`
    - `AI_ENDPOINT`
    - `AI_API_KEY`
    - `REVENUECAT_WEBHOOK_SECRET`
    - `FIREBASE_PROJECT_ID`
  3. Use **one real AI provider now**. Fastest path:
    - choose an **OpenAI-compatible** provider
    - set `AI_PROVIDER=openai-compatible`
    - set `AI_ENDPOINT` to that provider’s chat-completions endpoint
    - set `AI_MODEL` to the model you want
  4. Put those values into your actual Functions runtime/deployment secret flow.
    - If you want, after you have the values ready, I can help wire the exact local/deploy command path you choose.
  5. Generate a strong random `REVENUECAT_WEBHOOK_SECRET` and keep it exactly the same in both your backend runtime and RevenueCat webhook config.
- **Direct link(s)**
  - [OpenAI API keys](https://platform.openai.com/api-keys)
  - [OpenAI API docs](https://platform.openai.com/docs/api-reference)
  - [OpenRouter keys](https://openrouter.ai/keys)
  - [RevenueCat webhooks](https://www.revenuecat.com/docs/integrations/webhooks)
- **What you should prepare beforehand**
  - Decide which AI provider you want to use
  - A billing-ready account for that provider
  - A generated webhook secret value
- **What this unlocks for me once completed**
  - Real AI responses in assistant / goal plans / syllabus parsing
  - Safe billing webhook testing
- **Blocks**
  - **Development / Testing**

---

## 6. Set up RevenueCat and the real subscription products

- **Task**
  - Create the RevenueCat project/app, configure products, entitlement, offering, and webhook.
- **Why it is needed**
  - I already wired the app to link RevenueCat to Firebase user ids.
  - Until RevenueCat is real, billing is not truthful.
- **Where to do it**
  - RevenueCat dashboard
  - App Store Connect
- **How to do it**
  1. Create a RevenueCat project/app for the iOS app.
  2. Add your iOS app in RevenueCat.
  3. In App Store Connect, create the subscription products you want to use now:
    - monthly
    - annual
    - free trial if desired
  4. In RevenueCat:
    - create an **entitlement**
    - create an **offering**
    - attach the products
  5. Copy the **iOS public SDK key** and put it into:
    - `REVENUECAT_API_KEY` in the xcconfig files
  6. Configure the RevenueCat webhook to hit your Firebase function URL:
    - `https://us-central1-<YOUR_PROJECT_ID>.cloudfunctions.net/revenueCatWebhook`
  7. Set the webhook authorization header to exactly match `REVENUECAT_WEBHOOK_SECRET`.
- **Direct link(s)**
  - [RevenueCat Dashboard](https://app.revenuecat.com/)
  - [RevenueCat entitlements/offerings guide](https://www.revenuecat.com/docs/getting-started/entitlements)
  - [App Store Connect](https://appstoreconnect.apple.com/)
- **What you should prepare beforehand**
  - Apple Developer / App Store Connect access
  - Product ids you want to keep
  - The webhook secret from Step 5
- **What this unlocks for me once completed**
  - Real paywall / restore testing
  - Server-side subscription state updates via webhook
- **Blocks**
  - **Development / Testing**

---

## 7. Configure Apple Sign-In and Google Sign-In properly

- **Task**
  - Finish provider-side setup for Apple and Google auth.
- **Why it is needed**
  - The UI and app code exist, but provider auth cannot be tested live until the consoles are configured.
- **Where to do it**
  - Firebase Console
  - Apple Developer portal
- **How to do it**
  1. **Google Sign-In**
    - In Firebase Auth Providers, enable Google
    - Confirm support email / branding info if required
    - Use the values from `GoogleService-Info.plist` for the iOS app config
  2. **Sign in with Apple**
    - In Apple Developer, enable **Sign in with Apple** for the app id
    - Create the required Apple auth key / identifiers if Firebase asks for them
    - In Firebase Auth Providers, enable Apple and enter the required Apple-side values
  3. Make sure the app id matches:
    - `com.langqi.aicalendarapp`
- **Direct link(s)**
  - [Firebase Auth Providers](https://console.firebase.google.com/project/_/authentication/providers)
  - [Apple Developer — Identifiers](https://developer.apple.com/account/resources/identifiers/list)
  - [Apple Developer — Keys](https://developer.apple.com/account/resources/authkeys/list)
- **What you should prepare beforehand**
  - Apple Developer account access
  - Firebase project already created
  - `GoogleService-Info.plist` already downloaded
- **What this unlocks for me once completed**
  - Real Apple sign-in testing
  - Real Google sign-in testing
- **Blocks**
  - **Testing**

---

## 8. Configure APNs + Firebase Messaging for real push tests

- **Task**
  - Connect Apple Push Notifications to Firebase Cloud Messaging.
- **Why it is needed**
  - I already wired server push triggers and the app stores the FCM token.
  - Without APNs linkage, end-to-end push cannot be tested.
- **Where to do it**
  - Apple Developer portal
  - Firebase Console → Cloud Messaging
- **How to do it**
  1. In Apple Developer, create an **APNs Auth Key**.
  2. Download the `.p8` key once and store it safely.
  3. In Firebase Console → Cloud Messaging, upload:
    - APNs key
    - Key ID
    - Team ID
  4. Make sure Push Notifications are enabled for the app id in Apple Developer.
- **Direct link(s)**
  - [Apple Developer — Keys](https://developer.apple.com/account/resources/authkeys/list)
  - [Firebase Cloud Messaging settings](https://console.firebase.google.com/project/_/settings/cloudmessaging)
- **What you should prepare beforehand**
  - Apple Developer account
  - App id for `com.langqi.aicalendarapp`
- **What this unlocks for me once completed**
  - End-to-end push notification testing for the trigger I already added
- **Blocks**
  - **Testing / Launch**

---

## What to send me when you’re done

Send me these exact confirmations / values:

1. **Firebase project id**
2. **Whether `GoogleService-Info.plist` is added to the app target**
3. `**API_BASE_URL`**
4. **Whether `GOOGLE_CLIENT_ID` + `GOOGLE_REVERSED_CLIENT_ID` are filled**
5. **Whether `REVENUECAT_API_KEY` is filled**
6. **Whether AI env vars are set**
7. **Whether `REVENUECAT_WEBHOOK_SECRET` is set**
8. **Whether Apple + Google auth providers are enabled**
9. **Whether APNs is linked to Firebase Messaging**

Once those are done, I can continue with **live integration verification** instead of local-only development.