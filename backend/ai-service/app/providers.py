from typing import Any, Dict, Type, TypeVar

from pydantic import BaseModel

from app.config import Settings

try:
    from pydantic_ai import Agent
    from pydantic_ai.models.test import TestModel
except ImportError:  # pragma: no cover - allows syntax checks before dependencies are installed.
    Agent = None
    TestModel = None


OutputT = TypeVar("OutputT", bound=BaseModel)


class AIProviderUnavailable(Exception):
    pass


class StructuredAIRunner:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    async def run_structured(
        self,
        output_type: Type[OutputT],
        instructions: str,
        prompt: str,
        stub_output: Dict[str, Any],
    ) -> OutputT:
        if self._settings.ai_provider != "stub":
            raise AIProviderUnavailable("Only the stub AI provider is implemented in v1.")

        if Agent is None or TestModel is None:
            return output_type.model_validate(stub_output)

        agent = Agent(
            TestModel(custom_output_args=stub_output),
            output_type=output_type,
            instructions=instructions,
        )
        result = await agent.run(prompt)
        return result.output
