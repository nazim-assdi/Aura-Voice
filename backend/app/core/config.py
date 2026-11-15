from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AURA_",
        env_file=".env",
        extra="ignore",
    )

    app_name: str = "Aura Voice AI API"
    app_version: str = "0.3.0"
    environment: str = "development"

    # A production DATABASE_URL and JWT secret are deliberately required.
    # SQLite is used only for local development.
    database_url: str = ""
    auth_jwt_secret: str = ""
    access_token_minutes: int = 30
    secure_cookies: bool = True
    web_app_url: str = "https://aura-voice-studio.onrender.com"

    speech_provider: str = "none"
    cartesia_api_key: str = ""
    cartesia_model_id: str = "sonic-3.6"
    cartesia_stt_model_id: str = "ink-2"
    cartesia_voice_id: str = ""
    cartesia_version: str = "2026-08-14"
    cartesia_timeout_seconds: float = 45.0

    # Optional OpenAI-compatible LLM provider for translation and agent replies.
    llm_api_key: str = ""
    llm_base_url: str = "https://api.openai.com/v1"
    llm_model: str = ""

    cors_origins: str = (
        "http://localhost:3000,"
        "http://localhost:5173,"
        "http://localhost:8080,"
        "https://aura-voice-studio.onrender.com"
    )

    @property
    def parsed_cors_origins(self) -> list[str]:
        return [
            origin.strip()
            for origin in self.cors_origins.split(",")
            if origin.strip()
        ]

    @property
    def effective_database_url(self) -> str | None:
        if self.database_url.strip():
            url = self.database_url.strip()
            if url.startswith("postgres://"):
                url = url.replace("postgres://", "postgresql+asyncpg://", 1)
            elif url.startswith("postgresql://"):
                url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
            return url
        if self.environment.lower() not in {"production", "prod"}:
            return "sqlite+aiosqlite:///./aura_voice_dev.db"
        return None

    @property
    def auth_ready(self) -> bool:
        return bool(
            self.effective_database_url
            and self.auth_jwt_secret.strip()
            and len(self.auth_jwt_secret.strip()) >= 32
        )


settings = Settings()
