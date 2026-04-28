# AI Usage Retention

## Current Policy

- `users/{uid}/aiUsageDaily`: retained for 90 days.
- `users/{uid}/aiUsage`: retained for 180 days.

The daily quota documents only need to support recent quota/debug checks, so 90 days is enough for beta operations. The event log has a longer 180-day window so billing, abuse, and reliability investigations have more context without keeping AI usage metadata indefinitely.

## Cleanup Job

`cleanupAIUsageDocs` runs daily at 03:30 UTC with Firebase scheduled functions. It scans `users/{uid}/aiUsageDaily` and `users/{uid}/aiUsage`, deleting documents whose `createdAt` is older than the retention window.

The job deletes in bounded batches:

- up to 100 users per page
- up to 250 documents per user collection query
- up to 1,000 deletes per collection per run

This follows Firestore guidance to retrieve documents and delete them in smaller batches instead of trying to delete a collection in one operation.

## Verification

After deployment, verify:

1. Firebase deploy output creates or updates `cleanupAIUsageDocs`.
2. Google Cloud Scheduler shows the generated job for the function.
3. Function logs include `AI usage cleanup finished.` after the next scheduled run or manual Cloud Scheduler trigger.
4. Old `aiUsageDaily` and `aiUsage` docs are removed, while recent docs remain.

## Changing Retention

Change `AI_USAGE_DAILY_RETENTION_DAYS` or `AI_USAGE_EVENT_RETENTION_DAYS` in `backend/functions/src/ai/usageCleanup.ts`, then redeploy Functions. Do not reduce retention if there is an active billing, abuse, or support investigation that may need the older usage metadata.
