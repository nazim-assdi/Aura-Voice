from fastapi import APIRouter

from app.core.config import settings
from app.engines.registry import get_speech_provider

router = APIRouter()


@router.get("/capabilities")
async def capabilities() -> dict[str, object]:
    provider = get_speech_provider()
    provider_ready = provider.is_ready
    database_configured = bool(settings.effective_database_url)
    authenticated_workspace_ready = bool(database_configured and settings.auth_ready)

    tts_ready = provider_ready and authenticated_workspace_ready
    stt_ready = provider_ready and authenticated_workspace_ready
    translation_ready = bool(
        settings.llm_api_key.strip()
        and settings.llm_model.strip()
        and authenticated_workspace_ready
    )

    return {
        "product": "Aura Voice AI",
        "api_version": settings.app_version,
        "engine_mode": "hybrid",
        "configured_provider": provider.name,
        "speech_generation_ready": tts_ready,
        "voice_catalogue_ready": tts_ready,
        "voice_management_ready": authenticated_workspace_ready,
        "projects_ready": authenticated_workspace_ready,
        "private_audio_assets_ready": authenticated_workspace_ready,
        "daily_usage_limits_ready": authenticated_workspace_ready,
        "transcription_ready": stt_ready,
        "translation_ready": translation_ready,
        "dubbing_ready": bool(tts_ready and translation_ready and stt_ready),
        "realtime_tts_ready": tts_ready,
        "realtime_stt_ready": stt_ready,
        "realtime_conversation_ready": bool(tts_ready and stt_ready and translation_ready),
        "audio_editing_ready": authenticated_workspace_ready,
        "voice_favorites_ready": authenticated_workspace_ready,
        "voice_cloning_ready": False,
        "offline_inference_ready": False,
        "live_audio_routing_ready": False,
        "audio_formats": ["wav", "mp3"],
        "model_id": settings.cartesia_model_id if provider_ready else None,
        "security": {
            "registration_ready": authenticated_workspace_ready,
            "revocable_sessions": True,
            "rotating_refresh_tokens": True,
            "owner_scoped_projects": True,
            "private_audio_assets": True,
            "database_backed_rate_limits": True,
            "daily_generation_limit": 50,
            "daily_character_limit": 50000,
        },
        "note": (
            "Set a durable production AURA_DATABASE_URL and a 32+ character AURA_AUTH_JWT_SECRET to enable accounts, private projects, quotas and speech endpoints."
            if not authenticated_workspace_ready
            else (
                "Authenticated workspace is ready. Translation, dubbing and AI voice conversation also require an OpenAI-compatible LLM key and model."
                if not translation_ready
                else "Core authenticated voice production capabilities are configured."
            )
        ),
    }
