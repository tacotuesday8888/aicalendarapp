# iOS-First Architecture

## Boundary rule

- User-owned single-document CRUD stays client-side in iOS.
- AI-generated, billing-derived, cross-document, and security-sensitive logic moves to Cloud Functions.

## Client ownership

- SwiftUI UI and navigation
- Local feature state, validation, optimistic UX, and loading/error presentation
- Firebase Auth, Firestore CRUD for normal user data, Storage uploads, Analytics, Crashlytics, Messaging registration
- RevenueCat purchase and restore UI flows
- Superwall presentation
- EventKit permission handling and Apple Calendar import orchestration
- Study timer lifecycle and local reminder scheduling

## iOS to backend path

- The app signs users in with Firebase Auth.
- The app calls Cloud Functions through authenticated JSON HTTP endpoints using the Firebase Functions base URL in `API_BASE_URL`.
- The network layer attaches the current Firebase ID token as a bearer token automatically.
- If live backend config or SDKs are missing, the same feature surfaces fall back to local demo-safe behavior instead of breaking navigation.

## Server ownership

- LLM access and provider abstraction
- Prompt construction and context assembly
- Structured output validation and safety filters
- AI usage logging and rate limiting
- Syllabus parsing and import normalization
- RevenueCat webhook ingestion
- Subscription snapshots
- Draft validation, import commit, export, and deletion jobs

## AI baseline

The v1 AI backend uses Firebase Cloud Functions + Genkit. The app calls a Firebase Functions HTTP route, the server verifies the Firebase ID token, loads Firestore context, selects the workflow prompt, validates structured output, and returns JSON. Stub Genkit flows are used first; Vertex AI Gemini is the intended real provider after the stub path is proven.
