from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, field_validator, model_validator


class WorkflowName(str, Enum):
    assistant_chat = "assistant_chat"
    goal_plan_generation = "goal_plan_generation"
    vibe_feedback = "vibe_feedback"
    syllabus_import = "syllabus_import"


class AIRunRequest(BaseModel):
    workflow: WorkflowName
    payload: Dict[str, Any] = Field(default_factory=dict)


class AIError(BaseModel):
    code: str
    message: str


class AIErrorResponse(BaseModel):
    error: AIError


class AIRunResponse(BaseModel):
    workflow: WorkflowName
    result: Dict[str, Any]
    draftID: Optional[str] = None


class AssistantChatPayload(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    timezone: str = Field(min_length=1, max_length=80)
    currentScreen: Optional[str] = Field(default=None, max_length=120)
    date: Optional[str] = None
    contextHints: Dict[str, Any] = Field(default_factory=dict)


class DraftAction(BaseModel):
    type: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=160)
    dueAt: Optional[str] = None
    reason: str = Field(min_length=1, max_length=400)


class AssistantChatResult(BaseModel):
    message: str = Field(min_length=1, max_length=1600)
    draftActions: List[DraftAction] = Field(default_factory=list, max_length=3)


class GoalDetails(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    description: str = Field(default="", max_length=4000)


class GoalPlanPayload(BaseModel):
    goalID: Optional[str] = Field(default=None, min_length=1, max_length=200)
    goal: Optional[GoalDetails] = None
    timelineWeeks: int = Field(ge=1, le=52)
    startDate: str = Field(min_length=1, max_length=80)
    timezone: str = Field(min_length=1, max_length=80)

    @model_validator(mode="after")
    def require_goal_reference(self) -> "GoalPlanPayload":
        if not self.goalID and not self.goal:
            raise ValueError("Either goalID or goal details are required.")
        return self


class GoalMilestone(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    dueDate: str = Field(min_length=1, max_length=80)
    description: str = Field(min_length=1, max_length=600)


class GoalNextAction(BaseModel):
    title: str = Field(min_length=1, max_length=160)
    estimatedMinutes: int = Field(ge=1, le=480)
    priority: str

    @field_validator("priority")
    @classmethod
    def validate_priority(cls, value: str) -> str:
        if value not in {"low", "medium", "high"}:
            raise ValueError("priority must be low, medium, or high")
        return value


class GoalPlanResult(BaseModel):
    summary: str = Field(min_length=1, max_length=1000)
    milestones: List[GoalMilestone] = Field(default_factory=list)
    nextActions: List[GoalNextAction] = Field(min_length=3, max_length=5)


class VibeFeedbackPayload(BaseModel):
    reflectionText: str = Field(min_length=1, max_length=4000)
    timezone: str = Field(min_length=1, max_length=80)
    recentContext: Optional[Dict[str, Any]] = None


class VibeFeedbackResult(BaseModel):
    feedback: str = Field(min_length=1, max_length=1000)
    needs_escalation: bool = False


class SyllabusImportPayload(BaseModel):
    extractedText: str = Field(min_length=1, max_length=120000)
    currentDate: Optional[str] = None
    timezone: str = Field(min_length=1, max_length=80)


class SyllabusAssignment(BaseModel):
    title: str = Field(min_length=1, max_length=240)
    type: Optional[str] = Field(default=None, max_length=120)
    dueDate: Optional[str] = None
    confidence: str
    sourceText: str = Field(min_length=1, max_length=1000)

    @field_validator("confidence")
    @classmethod
    def validate_confidence(cls, value: str) -> str:
        if value not in {"low", "medium", "high"}:
            raise ValueError("confidence must be low, medium, or high")
        return value


class SyllabusCourse(BaseModel):
    name: str = Field(min_length=1, max_length=240)
    instructor: Optional[str] = Field(default=None, max_length=160)
    assignments: List[SyllabusAssignment] = Field(default_factory=list)


class SyllabusWarning(BaseModel):
    message: str = Field(min_length=1, max_length=600)
    sourceText: Optional[str] = Field(default=None, max_length=1000)


class SyllabusImportResult(BaseModel):
    courses: List[SyllabusCourse] = Field(default_factory=list)
    warnings: List[SyllabusWarning] = Field(default_factory=list)
