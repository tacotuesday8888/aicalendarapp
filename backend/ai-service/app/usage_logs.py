import asyncio
from typing import Any, Dict

from firebase_admin import firestore as admin_firestore
from google.cloud import firestore

from app.auth import ensure_firebase_app


class UsageLogger:
    def __init__(self) -> None:
        ensure_firebase_app()
        self._db = admin_firestore.client()

    async def log(self, user_id: str, workflow: str, metadata: Dict[str, Any]) -> None:
        await asyncio.to_thread(self._log_sync, user_id, workflow, metadata)

    def _log_sync(self, user_id: str, workflow: str, metadata: Dict[str, Any]) -> None:
        safe_metadata = {
            key: value
            for key, value in metadata.items()
            if key not in {"prompt", "systemPrompt", "apiKey", "token", "authorization"}
        }
        self._db.collection("users").document(user_id).collection("aiUsageLogs").add(
            {
                "workflow": workflow,
                "source": "ai-service",
                "metadata": safe_metadata,
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
