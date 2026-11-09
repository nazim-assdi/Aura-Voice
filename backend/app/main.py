from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.core.config import settings

app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    description="API foundation for Aura Voice AI. Speech providers are disabled until configured.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.parsed_cors_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization"],
)
app.include_router(api_router, prefix="/api/v1")


@app.get("/health", tags=["system"])
async def health() -> dict[str, object]:
    return {
        "ok": True,
        "service": "aura-voice-api",
        "version": settings.app_version,
        "speech_provider": settings.speech_provider,
        "speech_ready": False,
    }
