from fastapi import APIRouter

from app.core.config import settings
from app.engines.registry import get_speech_provider

router = APIRouter()


@router.get("/capabilities")
async def capabilities() -> dict[str, object]:
    provider = get_speech_provider()
    ready = provider.is_ready
    return {
        "product": "Aura Voice AI",
        "api_version": settings.app_version,
        "engine_mode": "hybrid",
        "configured_provider": provider.name,
        "speech_generation_ready": ready,
        "voice_catalogue_ready": ready,
        "voice_cloning_ready": False,
        "offline_inference_ready": False,
        "live_audio_routing_ready": False,
        "audio_formats": ["wav"],
        "model_id": settings.cartesia_model_id if ready else None,
        "note": (
            "Cartesia Sonic TTS is configured on the backend."
            if ready
            else "Configure Cartesia on the backend to enable speech generation."
        ),
    }
