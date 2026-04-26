from functools import lru_cache
import os
from typing import List

from pydantic import BaseModel, Field


class Settings(BaseModel):
    firebase_project_id: str = Field(default="", alias="FIREBASE_PROJECT_ID")
    environment: str = Field(default="dev", alias="ENVIRONMENT")
    ai_provider: str = Field(default="stub", alias="AI_PROVIDER")
    ai_model: str = Field(default="stub", alias="AI_MODEL")
    ai_api_key: str = Field(default="", alias="AI_API_KEY")
    allowed_origins: str = Field(default="*", alias="ALLOWED_ORIGINS")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")
    enable_streaming: bool = Field(default=True, alias="ENABLE_STREAMING")
    max_tokens: int = Field(default=2048, alias="MAX_TOKENS")
    rate_limit_per_day: int = Field(default=50, alias="RATE_LIMIT_PER_DAY")

    @property
    def cors_origins(self) -> List[str]:
        values = [origin.strip() for origin in self.allowed_origins.split(",")]
        return [origin for origin in values if origin]


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    values = {}
    for field in Settings.model_fields.values():
        env_name = str(field.alias)
        if env_name in os.environ:
            values[env_name] = os.environ[env_name]
    return Settings.model_validate(values)
