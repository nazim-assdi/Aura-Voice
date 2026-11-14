from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.core.config import settings
from app.engines.registry import get_speech_provider

app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    description="Aura Voice AI API with an optional Cartesia Sonic speech provider.",
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
    provider = get_speech_provider()
    return {
        "ok": True,
        "service": "aura-voice-api",
        "version": settings.app_version,
        "speech_provider": provider.name,
        "speech_ready": provider.is_ready,
    }
