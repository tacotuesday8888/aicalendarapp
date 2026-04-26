from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import ValidationError

from app.auth import AuthenticatedUser, get_current_user
from app.config import Settings, get_settings
from app.firestore_repo import FirestoreRepository
from app.providers import StructuredAIRunner
from app.rate_limits import FirestoreRateLimiter, RateLimitExceeded
from app.schemas import AIError, AIErrorResponse, AIRunRequest, WorkflowName
from app.usage_logs import UsageLogger
from app.workflows import WorkflowService


settings = get_settings()
app = FastAPI(title="AI Service", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials="*" not in settings.cors_origins,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
)


def error_response(code: str, message: str, status_code: int) -> JSONResponse:
    payload = AIErrorResponse(error=AIError(code=code, message=message))
    return JSONResponse(status_code=status_code, content=payload.model_dump())


@app.exception_handler(RequestValidationError)
async def request_validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return error_response("invalid_payload", "Invalid request.", status.HTTP_422_UNPROCESSABLE_ENTITY)


@app.exception_handler(ValidationError)
async def pydantic_validation_error_handler(request: Request, exc: ValidationError) -> JSONResponse:
    return error_response("invalid_payload", "Invalid request.", status.HTTP_422_UNPROCESSABLE_ENTITY)


@app.exception_handler(RateLimitExceeded)
async def rate_limit_error_handler(request: Request, exc: RateLimitExceeded) -> JSONResponse:
    return error_response("rate_limited", "Daily AI limit reached.", status.HTTP_429_TOO_MANY_REQUESTS)


@app.exception_handler(HTTPException)
async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
    code = "request_failed"
    if exc.status_code == status.HTTP_401_UNAUTHORIZED:
        code = "unauthenticated"
    elif exc.status_code == status.HTTP_400_BAD_REQUEST:
        code = "invalid_request"
    elif exc.status_code == status.HTTP_404_NOT_FOUND:
        code = "not_found"

    message = exc.detail if isinstance(exc.detail, str) else "Request failed."
    return error_response(code, message, exc.status_code)


def get_workflow_service() -> WorkflowService:
    current_settings = get_settings()
    return WorkflowService(
        settings=current_settings,
        repo=FirestoreRepository(),
        ai_runner=StructuredAIRunner(current_settings),
        rate_limiter=FirestoreRateLimiter(current_settings.rate_limit_per_day),
        usage_logger=UsageLogger(),
    )


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/version")
async def version() -> dict:
    current_settings = get_settings()
    return {
        "service": "ai-service",
        "version": app.version,
        "environment": current_settings.environment,
        "aiProvider": current_settings.ai_provider,
        "aiModel": current_settings.ai_model,
    }


@app.post("/ai/run")
async def run_ai(
    request: AIRunRequest,
    user: AuthenticatedUser = Depends(get_current_user),
    workflows: WorkflowService = Depends(get_workflow_service),
):
    try:
        if (
            request.workflow == WorkflowName.assistant_chat
            and get_settings().enable_streaming
        ):
            return StreamingResponse(
                workflows.stream_assistant_chat(user.uid, request.payload),
                media_type="text/event-stream",
            )

        return await workflows.run(user.uid, request)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(exc),
        ) from exc
