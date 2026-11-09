from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="AURA_",
        env_file=".env",
        extra="ignore",
    )

    app_name: str = "Aura Voice AI API"
    app_version: str = "0.1.0"
    environment: str = "development"
    speech_provider: str = "none"
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
