# Full No-Code Checklist (Do Now, Free Only)

This checklist is based on the current project state. It includes only non-code tasks that are free, necessary right now, and related to setup, configuration, or preparation.

---

- Task: Create a Firebase project
- Action: Go to Firebase Console, create a new project, and choose a project ID you will use consistently for backend deployment and iOS app registration.
- Location: https://console.firebase.google.com
- Blocking: Yes

- Task: Enable Firebase Authentication
- Action: In the Firebase project, open Authentication, click "Get started," and enable `Email/Password`. Enable Google sign-in as well if you plan to use the Google auth flow already wired into the app.
- Location: Firebase Console → Build → Authentication
- Blocking: Yes

- Task: Create a Firestore database
- Action: Open Firestore Database, create the database, choose Production mode, and pick the region you intend to keep for the project.
- Location: Firebase Console → Build → Firestore Database
- Blocking: Yes

- Task: Create Firebase Storage
- Action: Open Storage, get started, and choose the same region as Firestore.
- Location: Firebase Console → Build → Storage
- Blocking: Yes

- Task: Register the iOS app in Firebase
- Action: Add an iOS app to the Firebase project using bundle ID `com.langqi.aicalendarapp`.
- Location: Firebase Console → Project Settings → Your apps → Add app → iOS
- Blocking: Yes

- Task: Download the real `GoogleService-Info.plist`
- Action: Download the generated `GoogleService-Info.plist` for the registered iOS app and keep it available for the project. The repo currently only contains a template file, not the real plist.
- Location: Firebase Console → Project Settings → Your iOS app
- Blocking: Yes

- Task: Record Google client identifiers from Firebase config
- Action: Open the downloaded `GoogleService-Info.plist` and note the values for `CLIENT_ID` and `REVERSED_CLIENT_ID`. The app expects both values in build configuration.
- Location: Downloaded `GoogleService-Info.plist`
- Blocking: Yes

- Task: Create a free LLM provider account
- Action: Create an account with a provider that offers a free tier and supports the app's backend configuration. Record the provider name you choose.
- Location: https://aistudio.google.com or https://console.groq.com
- Blocking: Yes

- Task: Generate an LLM API key
- Action: Create an API key for the provider you selected and keep it available for backend environment setup.
- Location: Your chosen LLM provider dashboard
- Blocking: Yes

- Task: Record the AI endpoint and model name
- Action: Note the exact API endpoint URL and model identifier required by your chosen provider. The backend expects `AI_ENDPOINT`, `AI_MODEL`, and `AI_API_KEY`.
- Location: Your chosen LLM provider documentation or dashboard
- Blocking: Yes

- Task: Decide the Firebase region for backend consistency
- Action: Confirm the region you used for Firestore and Storage so the same region can be used consistently for backend deployment and service configuration.
- Location: Firebase Console
- Blocking: Yes

- Task: Keep the Firebase project ID ready for local setup
- Action: Copy the exact Firebase project ID and keep it available. It is required for `.firebaserc`, backend environment configuration, and the deployed functions URL.
- Location: Firebase Console → Project Settings
- Blocking: Yes

- Task: Enable local Firebase CLI login on your machine
- Action: Make sure you are ready to authenticate `firebase login` from your terminal session when the deployment step starts. This is a manual sign-in step even if the code-side deployment is delegated.
- Location: Local terminal browser/device auth flow
- Blocking: Yes

- Task: Confirm whether Google sign-in is part of the immediate launch scope
- Action: Decide whether Google sign-in should be active right now. If yes, keep Authentication → Google enabled in Firebase and preserve the client ID values from the plist.
- Location: Firebase Console and project setup notes
- Blocking: No

- Task: Verify Apple Developer work is intentionally deferred
- Action: Confirm that Apple Developer enrollment, Sign in with Apple, TestFlight, App Store Connect, IAP, and RevenueCat are not part of the immediate free setup pass, since they either require payment or are downstream.
- Location: Your release/setup plan
- Blocking: No

---

## What You Should Hand To The Agent After Completing This

Once the items above are done, provide these exact inputs to the agent so the code-side setup can be completed:

- `Firebase project ID`
- `Firebase region`
- The real `GoogleService-Info.plist`
- `CLIENT_ID` from the plist
- `REVERSED_CLIENT_ID` from the plist
- `AI_API_KEY`
- `AI_ENDPOINT`
- `AI_MODEL`

At that point, the remaining repo-side configuration can be completed without additional paid setup.
