from fastapi import APIRouter

from app.core.config import settings
from app.engines.registry import get_speech_provider

router = APIRouter()


@router.get("/capabilities")
async def capabilities() -> dict[str, object]:
    provider = get_speech_provider()
    ready = provider.is_ready
    database_ready = bool(settings.effective_database_url)
    authenticated_workspace_ready = bool(database_ready and settings.auth_ready)
    return {
        "product": "Aura Voice AI",
        "api_version": settings.app_version,
        "engine_mode": "hybrid",
        "configured_provider": provider.name,
        "speech_generation_ready": ready and authenticated_workspace_ready,
        "voice_catalogue_ready": ready and authenticated_workspace_ready,
        "voice_management_ready": authenticated_workspace_ready,
        "projects_ready": authenticated_workspace_ready,
        "private_audio_assets_ready": authenticated_workspace_ready,
        "daily_usage_limits_ready": authenticated_workspace_ready,
        "transcription_ready": ready and authenticated_workspace_ready,
        "translation_ready": bool(settings.llm_api_key and settings.llm_model and authenticated_workspace_ready),
        "dubbing_ready": bool(ready and settings.llm_api_key and settings.llm_model and authenticated_workspace_ready),
        "realtime_stt_ready": bool(ready and authenticated_workspace_ready),
        "realtime_conversation_ready": bool(ready and settings.llm_api_key and settings.llm_model and authenticated_workspace_ready),
        "audio_editing_ready": True,
        "voice_cloning_ready": False,
        "offline_inference_ready": False,
        "live_audio_routing_ready": False,
        "audio_formats": ["wav", "mp3"],
        "model_id": settings.cartesia_model_id if ready else None,
        "security": {
            "authenticated_tts": True,
            "owner_scoped_projects": True,
            "database_backed_rate_limits": True,
            "daily_generation_quota": 50,
            "daily_character_quota": 50000,
        },
        "note": (
            "API key detected. User accounts and projects become available after a persistent production database and JWT secret are configured."
            if not authenticated_workspace_ready
            else "Authenticated workspace is ready. Optional translation and AI conversation also require an OpenAI-compatible LLM key."
        ),
    }
