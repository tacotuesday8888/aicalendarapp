# AI Efficiency Calendar App

AI Efficiency Calendar App is an iPhone-first SwiftUI planning app for students. It combines calendar planning, goals, study sessions, reflections, syllabus imports, subscriptions, and AI-assisted planning.

## Project Structure

- `iOSApp/` - SwiftUI iOS app source, features, services, design system, and app resources.
- `aicalendarapp.xcodeproj/` - Xcode project.
- `backend/functions/` - Firebase Cloud Functions for privileged server work.
- `backend/ai-service/` - Inactive FastAPI AI service prototype retained for reference; v1 AI uses Firebase Functions + Genkit.
- `backend/firestore/` - Firestore rules and indexes.
- `backend/storage/` - Firebase Storage rules.
- `shared/` - Shared contracts and analytics event names.
- `docs/` - Product, architecture, and runbook documentation.

## Run the iOS App

1. Open `aicalendarapp.xcodeproj` in Xcode.
2. Let Xcode resolve Swift Package dependencies.
3. Add the required local config files listed below.
4. Select the `aicalendarapp` scheme.
5. Build and run on a simulator or device.

The app can fall back to local/demo-safe behavior when some live services are missing, but real Firebase, billing, Google sign-in, and backend flows require local configuration.

## Required Local Config

These files are intentionally ignored by Git:

- `.firebaserc` - local Firebase project aliases.
- `iOSApp/Resources/Config/GoogleService-Info.plist` - real Firebase iOS app config.
- `iOSApp/Resources/Config/Secrets.xcconfig` - local app secrets and service IDs.
- `backend/functions/.env.*` - local Firebase Functions environment files.

Use the templates in the repo as starting points:

- `.firebaserc.template`
- `iOSApp/Resources/Config/GoogleService-Info.plist.template`
- `iOSApp/Resources/Config/Secrets.template.xcconfig`
- `backend/config/.env.example`

## Backend Basics

Firebase Cloud Functions are the main backend boundary for AI work, imports, subscription webhooks, account export, and account deletion. See:

- `shared/contracts/backend-functions.md`
- `docs/runbooks/backend-setup.md`

Firestore and Storage rules live in `backend/firestore/` and `backend/storage/`.

## Safety

Do not commit real service config, API keys, environment files, local logs, build outputs, `node_modules`, or generated Firebase function output. The repo `.gitignore` is set up to keep those local.
