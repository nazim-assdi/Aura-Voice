from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AURA_",
        env_file=".env",
        extra="ignore",
    )

    app_name: str = "Aura Voice Studio API"
    app_version: str = "0.1.0"
    environment: str = "development"
    speech_provider: str = "edge"
    elevenlabs_api_key: str = ""
    elevenlabs_model: str = "eleven_v4"
    cartesia_api_key: str = ""
    cartesia_model: str = "sonic-3.6"
    cartesia_api_version: str = "2026-08-14"
    cors_origins: str = (
        "http://localhost:3000,"
        "http://localhost:5173,"
        "http://localhost:8080"
    )

    @property
    def parsed_cors_origins(self) -> list[str]:
        return [
            origin.strip()
            for origin in self.cors_origins.split(",")
            if origin.strip()
        ]


settings = Settings()
