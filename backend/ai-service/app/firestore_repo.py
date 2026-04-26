import asyncio
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from firebase_admin import firestore as admin_firestore
from google.cloud import firestore

from app.auth import ensure_firebase_app
from app.schemas import (
    AssistantChatPayload,
    AssistantChatResult,
    GoalPlanPayload,
    GoalPlanResult,
    SyllabusImportPayload,
    SyllabusImportResult,
    VibeFeedbackPayload,
)


class FirestoreRepository:
    def __init__(self) -> None:
        ensure_firebase_app()
        self._db = admin_firestore.client()

    def _user_doc(self, user_id: str):
        return self._db.collection("users").document(user_id)

    def _user_collection(self, user_id: str, collection: str):
        return self._user_doc(user_id).collection(collection)

    async def load_assistant_context(self, user_id: str, payload: AssistantChatPayload) -> Dict[str, Any]:
        return await asyncio.to_thread(self._load_assistant_context_sync, user_id, payload)

    def _load_assistant_context_sync(self, user_id: str, payload: AssistantChatPayload) -> Dict[str, Any]:
        goals = self._get_recent_collection_documents(user_id, "goals", limit=10)
        planner_blocks = self._get_recent_collection_documents(user_id, "plannerBlocks", limit=20)
        assignments = self._get_recent_collection_documents(user_id, "assignments", limit=20)
        return {
            "currentScreen": payload.currentScreen,
            "date": payload.date,
            "contextHints": payload.contextHints,
            "goals": goals,
            "plannerBlocks": planner_blocks,
            "assignments": assignments,
        }

    async def load_goal_context(self, user_id: str, payload: GoalPlanPayload) -> Dict[str, Any]:
        return await asyncio.to_thread(self._load_goal_context_sync, user_id, payload)

    def _load_goal_context_sync(self, user_id: str, payload: GoalPlanPayload) -> Dict[str, Any]:
        if payload.goal:
            return {"goal": payload.goal.model_dump()}

        if not payload.goalID:
            return {"goal": None}

        snapshot = self._user_collection(user_id, "goals").document(payload.goalID).get()
        return {"goal": snapshot.to_dict() if snapshot.exists else None}

    async def load_vibe_context(self, user_id: str, payload: VibeFeedbackPayload) -> Dict[str, Any]:
        return await asyncio.to_thread(self._load_vibe_context_sync, user_id, payload)

    def _load_vibe_context_sync(self, user_id: str, payload: VibeFeedbackPayload) -> Dict[str, Any]:
        vibe_checks = self._get_recent_collection_documents(user_id, "vibeChecks", limit=5)
        return {
            "recentContext": payload.recentContext or {},
            "recentVibeChecks": vibe_checks,
        }

    async def save_assistant_draft(
        self, user_id: str, result: AssistantChatResult, context: Dict[str, Any]
    ) -> Optional[str]:
        if not result.draftActions:
            return None
        return await asyncio.to_thread(self._save_assistant_draft_sync, user_id, result, context)

    def _save_assistant_draft_sync(
        self, user_id: str, result: AssistantChatResult, context: Dict[str, Any]
    ) -> str:
        doc = self._user_collection(user_id, "assistantDraftArtifacts").document()
        doc.set(
            {
                "id": doc.id,
                "userID": user_id,
                "status": "pending",
                "source": "ai-service",
                "workflow": "assistant_chat",
                "draftActions": [action.model_dump() for action in result.draftActions],
                "contextSummary": {
                    "currentScreen": context.get("currentScreen"),
                    "date": context.get("date"),
                },
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id

    async def save_goal_plan_draft(
        self, user_id: str, payload: GoalPlanPayload, result: GoalPlanResult
    ) -> str:
        return await asyncio.to_thread(self._save_goal_plan_draft_sync, user_id, payload, result)

    def _save_goal_plan_draft_sync(
        self, user_id: str, payload: GoalPlanPayload, result: GoalPlanResult
    ) -> str:
        doc = self._user_collection(user_id, "goalPlans").document()
        doc.set(
            {
                "id": doc.id,
                "goalID": payload.goalID or "",
                "summary": result.summary,
                "suggestedTimelineWeeks": payload.timelineWeeks,
                "milestones": [milestone.model_dump() for milestone in result.milestones],
                "nextActions": [action.model_dump() for action in result.nextActions],
                "status": "pending",
                "source": "ai-service",
                "createdAt": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id

    async def save_syllabus_import_draft(
        self, user_id: str, payload: SyllabusImportPayload, result: SyllabusImportResult
    ) -> str:
        return await asyncio.to_thread(self._save_syllabus_import_draft_sync, user_id, payload, result)

    def _save_syllabus_import_draft_sync(
        self, user_id: str, payload: SyllabusImportPayload, result: SyllabusImportResult
    ) -> str:
        doc = self._user_collection(user_id, "imports").document()
        doc.set(
            {
                "id": doc.id,
                "sourceName": "ai-service-syllabus-import",
                "status": "completed",
                "source": "ai-service",
                "rawTextLength": len(payload.extractedText),
                "extracted": result.model_dump(),
                "createdAt": firestore.SERVER_TIMESTAMP,
                "committedAt": None,
            }
        )
        return doc.id

    def _get_recent_collection_documents(self, user_id: str, collection: str, limit: int) -> List[Dict[str, Any]]:
        documents = (
            self._user_collection(user_id, collection)
            .limit(limit)
            .stream()
        )
        return [self._normalize_document(snapshot.to_dict() or {}) for snapshot in documents]

    def _normalize_document(self, value: Dict[str, Any]) -> Dict[str, Any]:
        normalized = {}
        for key, child in value.items():
            normalized[key] = self._normalize_value(child)
        return normalized

    def _normalize_value(self, value: Any) -> Any:
        if isinstance(value, datetime):
            if value.tzinfo is None:
                value = value.replace(tzinfo=timezone.utc)
            return value.isoformat()
        if isinstance(value, list):
            return [self._normalize_value(item) for item in value]
        if isinstance(value, dict):
            return {key: self._normalize_value(child) for key, child in value.items()}
        return value
