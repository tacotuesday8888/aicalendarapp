import json
from typing import Any, AsyncIterator, Dict

from app.config import Settings
from app.firestore_repo import FirestoreRepository
from app.prompts.assistant_chat import build_assistant_chat_instructions
from app.prompts.goal_plan_generation import build_goal_plan_generation_instructions
from app.prompts.syllabus_import import build_syllabus_import_instructions
from app.prompts.vibe_feedback import build_vibe_feedback_instructions
from app.providers import StructuredAIRunner
from app.rate_limits import FirestoreRateLimiter
from app.schemas import (
    AIRunRequest,
    AIRunResponse,
    AssistantChatPayload,
    AssistantChatResult,
    GoalPlanPayload,
    GoalPlanResult,
    SyllabusImportPayload,
    SyllabusImportResult,
    VibeFeedbackPayload,
    VibeFeedbackResult,
    WorkflowName,
)
from app.usage_logs import UsageLogger


class WorkflowService:
    def __init__(
        self,
        settings: Settings,
        repo: FirestoreRepository,
        ai_runner: StructuredAIRunner,
        rate_limiter: FirestoreRateLimiter,
        usage_logger: UsageLogger,
    ) -> None:
        self._settings = settings
        self._repo = repo
        self._ai_runner = ai_runner
        self._rate_limiter = rate_limiter
        self._usage_logger = usage_logger

    async def run(self, user_id: str, request: AIRunRequest) -> AIRunResponse:
        await self._rate_limiter.check_and_increment(user_id, request.workflow.value)

        if request.workflow == WorkflowName.assistant_chat:
            result, draft_id = await self._run_assistant_chat(user_id, request.payload)
        elif request.workflow == WorkflowName.goal_plan_generation:
            result, draft_id = await self._run_goal_plan_generation(user_id, request.payload)
        elif request.workflow == WorkflowName.vibe_feedback:
            result, draft_id = await self._run_vibe_feedback(user_id, request.payload)
        elif request.workflow == WorkflowName.syllabus_import:
            result, draft_id = await self._run_syllabus_import(user_id, request.payload)
        else:
            raise ValueError("Unsupported workflow.")

        await self._usage_logger.log(
            user_id,
            request.workflow.value,
            {"provider": self._settings.ai_provider, "model": self._settings.ai_model},
        )
        return AIRunResponse(workflow=request.workflow, result=result, draftID=draft_id)

    async def stream_assistant_chat(self, user_id: str, payload: Dict[str, Any]) -> AsyncIterator[str]:
        await self._rate_limiter.check_and_increment(user_id, WorkflowName.assistant_chat.value)
        result, draft_id = await self._run_assistant_chat(user_id, payload)

        response = AIRunResponse(
            workflow=WorkflowName.assistant_chat,
            result=result,
            draftID=draft_id,
        )
        await self._usage_logger.log(
            user_id,
            WorkflowName.assistant_chat.value,
            {
                "provider": self._settings.ai_provider,
                "model": self._settings.ai_model,
                "streaming": True,
            },
        )
        # Stub provider cannot produce true token deltas; real model streaming plugs in here.
        yield _sse_event("delta", {"text": result.get("message", "")})
        yield _sse_event("final", response.model_dump())

    async def _run_assistant_chat(self, user_id: str, payload_data: Dict[str, Any]):
        payload = AssistantChatPayload.model_validate(payload_data)
        context = await self._repo.load_assistant_context(user_id, payload)
        stub = _assistant_stub_output(payload, context)
        result = await self._ai_runner.run_structured(
            AssistantChatResult,
            build_assistant_chat_instructions(),
            _json_prompt({"payload": payload.model_dump(), "context": context}),
            stub,
        )
        draft_id = await self._repo.save_assistant_draft(user_id, result, context)
        return result.model_dump(), draft_id

    async def _run_goal_plan_generation(self, user_id: str, payload_data: Dict[str, Any]):
        payload = GoalPlanPayload.model_validate(payload_data)
        context = await self._repo.load_goal_context(user_id, payload)
        stub = _goal_plan_stub_output(payload, context)
        result = await self._ai_runner.run_structured(
            GoalPlanResult,
            build_goal_plan_generation_instructions(),
            _json_prompt({"payload": payload.model_dump(), "context": context}),
            stub,
        )
        draft_id = await self._repo.save_goal_plan_draft(user_id, payload, result)
        return result.model_dump(), draft_id

    async def _run_vibe_feedback(self, user_id: str, payload_data: Dict[str, Any]):
        payload = VibeFeedbackPayload.model_validate(payload_data)
        context = await self._repo.load_vibe_context(user_id, payload)
        stub = _vibe_stub_output(payload)
        result = await self._ai_runner.run_structured(
            VibeFeedbackResult,
            build_vibe_feedback_instructions(),
            _json_prompt({"payload": payload.model_dump(), "context": context}),
            stub,
        )
        return result.model_dump(), None

    async def _run_syllabus_import(self, user_id: str, payload_data: Dict[str, Any]):
        payload = SyllabusImportPayload.model_validate(payload_data)
        stub = _syllabus_stub_output(payload)
        result = await self._ai_runner.run_structured(
            SyllabusImportResult,
            build_syllabus_import_instructions(),
            _json_prompt({"payload": payload.model_dump()}),
            stub,
        )
        draft_id = await self._repo.save_syllabus_import_draft(user_id, payload, result)
        return result.model_dump(), draft_id


def _json_prompt(value: Dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def _sse_event(event: str, data: Dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=True)}\n\n"


def _assistant_stub_output(payload: AssistantChatPayload, context: Dict[str, Any]) -> Dict[str, Any]:
    goals = context.get("goals") or []
    if goals:
        message = "Start with the highest-impact task tied to your current goals, then protect one short focus block."
    else:
        message = "Pick one concrete task for the next 25 minutes, then reassess your plan."

    return {
        "message": message,
        "draftActions": [
            {
                "type": "study_block",
                "title": "Plan one focused study block",
                "dueAt": None,
                "reason": "A short planned block lowers friction and keeps the next step specific.",
            }
        ],
    }


def _goal_plan_stub_output(payload: GoalPlanPayload, context: Dict[str, Any]) -> Dict[str, Any]:
    goal = context.get("goal") or {}
    title = goal.get("title") or (payload.goal.title if payload.goal else "this goal")
    return {
        "summary": f"Make steady progress on {title} with weekly checkpoints and a small first step today.",
        "milestones": [
            {
                "title": "Clarify the finish line",
                "dueDate": payload.startDate,
                "description": "Define what done looks like and list the main constraints.",
            }
        ],
        "nextActions": [
            {"title": "Write the first concrete task", "estimatedMinutes": 10, "priority": "high"},
            {"title": "Block one work session", "estimatedMinutes": 5, "priority": "medium"},
            {"title": "Identify the first blocker", "estimatedMinutes": 10, "priority": "medium"},
        ],
    }


def _vibe_stub_output(payload: VibeFeedbackPayload) -> Dict[str, Any]:
    lowered = payload.reflectionText.lower()
    danger_terms = ["suicide", "kill myself", "self-harm", "hurt myself", "end my life"]
    if any(term in lowered for term in danger_terms):
        return {
            "feedback": "If you might be in immediate danger, contact emergency services now or reach out to a trusted person who can stay with you. You do not have to handle this alone.",
            "needs_escalation": True,
        }

    return {
        "feedback": "Take one small step that makes the next hour easier: shrink the task, clear one blocker, or start a short focus block.",
        "needs_escalation": False,
    }


def _syllabus_stub_output(payload: SyllabusImportPayload) -> Dict[str, Any]:
    first_line = next((line.strip() for line in payload.extractedText.splitlines() if line.strip()), "Imported Course")
    return {
        "courses": [
            {
                "name": first_line[:120],
                "instructor": None,
                "assignments": [],
            }
        ],
        "warnings": [
            {
                "message": "Stub parser did not extract assignments. Review the syllabus text before importing.",
                "sourceText": None,
            }
        ],
    }
