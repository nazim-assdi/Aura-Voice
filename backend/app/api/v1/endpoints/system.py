from fastapi import APIRouter

from app.core.config import settings
from app.engines.registry import get_speech_provider

router = APIRouter()


@router.get("/capabilities")
async def capabilities() -> dict[str, object]:
    provider = get_speech_provider()
    return {
        "product": "Aura Voice AI",
        "api_version": settings.app_version,
        "engine_mode": "hybrid",
        "configured_provider": provider.name,
        "speech_generation_ready": provider.is_ready,
        "voice_cloning_ready": False,
        "offline_inference_ready": False,
        "live_audio_routing_ready": False,
        "audio_formats": ["wav", "mp3", "ogg", "flac"],
        "note": "Formats are planned targets, not available until a provider is installed and tested.",
    }
