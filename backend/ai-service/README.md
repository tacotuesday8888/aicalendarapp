# AI Service

Dedicated FastAPI backend for cloud-powered AI workflows.

## Local shape

- `GET /health`
- `GET /version`
- `POST /ai/run`

The service verifies Firebase ID tokens from `Authorization: Bearer <token>`, uses the verified `uid`, loads Firestore context server-side, and runs workflow-specific Pydantic AI flows.

## v1 provider

`AI_PROVIDER=stub` is the only implemented provider in this first pass. It uses deterministic schema-valid outputs so auth, Firestore context, draft storage, streaming, and iOS integration can be tested before a real LLM is added.

## Environment

```env
FIREBASE_PROJECT_ID=<project-id>
ENVIRONMENT=dev
AI_PROVIDER=stub
AI_MODEL=stub
AI_API_KEY=
ALLOWED_ORIGINS=*
LOG_LEVEL=INFO
ENABLE_STREAMING=true
MAX_TOKENS=2048
RATE_LIMIT_PER_DAY=50
```

Do not put LLM API keys in the iOS app bundle.
