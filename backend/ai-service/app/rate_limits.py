import asyncio
from datetime import datetime, timezone

from firebase_admin import firestore as admin_firestore
from google.cloud import firestore

from app.auth import ensure_firebase_app


class RateLimitExceeded(Exception):
    pass


class FirestoreRateLimiter:
    def __init__(self, max_per_day: int) -> None:
        ensure_firebase_app()
        self._db = admin_firestore.client()
        self._max_per_day = max_per_day

    async def check_and_increment(self, user_id: str, workflow: str) -> None:
        await asyncio.to_thread(self._check_and_increment_sync, user_id, workflow)

    def _check_and_increment_sync(self, user_id: str, workflow: str) -> None:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        doc_id = f"{user_id}_{today}_{workflow}"
        doc = self._db.collection("aiRateLimits").document(doc_id)
        transaction = self._db.transaction()

        @firestore.transactional
        def update_in_transaction(transaction):
            snapshot = doc.get(transaction=transaction)
            current_count = 0
            if snapshot.exists:
                current_count = int((snapshot.to_dict() or {}).get("count", 0))

            if current_count >= self._max_per_day:
                raise RateLimitExceeded("Daily AI limit reached.")

            transaction.set(
                doc,
                {
                    "userID": user_id,
                    "workflow": workflow,
                    "date": today,
                    "count": current_count + 1,
                    "updatedAt": firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )

        update_in_transaction(transaction)
