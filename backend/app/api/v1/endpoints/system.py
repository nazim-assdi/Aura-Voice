from fastapi import APIRouter

from app.core.config import settings
from app.engines.registry import get_speech_provider

router = APIRouter()


@router.get("/capabilities")
async def capabilities() -> dict[str, object]:
    provider = get_speech_provider()
    return {
        "product": "Aura Voice Studio",
        "api_version": settings.app_version,
        "engine_mode": "hybrid",
        "configured_provider": provider.name,
        "speech_generation_ready": provider.is_ready,
        "speech_mode": "online_neural" if provider.is_ready else "unavailable",
        "recording_ready": False,
        "multitrack_editing_ready": False,
        "audio_processing_ready": False,
        "transcription_ready": False,
        "translation_ready": False,
        "dubbing_ready": False,
        "mastering_ready": False,
        "voice_cloning_ready": False,
        "offline_inference_ready": False,
        "live_audio_routing_ready": False,
        "note": "Neural speech generation uses the configured online provider. Recording and editing continue to run locally.",
    }
