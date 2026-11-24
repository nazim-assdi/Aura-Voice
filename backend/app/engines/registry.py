from app.core.config import settings
from app.engines.base import SpeechProvider, UnavailableSpeechProvider
from app.engines.edge_tts import get_edge_tts_provider
from app.engines.elevenlabs_tts import ElevenLabsSpeechProvider
from app.engines.cartesia_tts import CartesiaSpeechProvider


def get_speech_provider() -> SpeechProvider:
    """Resolve a configured speech adapter; unknown names fail closed."""
    provider_name = settings.speech_provider.strip().lower() or "none"
    if provider_name in {"edge", "edge-tts"}:
        return get_edge_tts_provider()
    if provider_name in {"elevenlabs", "elevenlabs-v4", "eleven_v4"}:
        api_key = settings.elevenlabs_api_key.strip()
        if not api_key:
            return UnavailableSpeechProvider(provider_name="elevenlabs (API key required)")
        return ElevenLabsSpeechProvider(
            api_key=api_key,
            model_id=settings.elevenlabs_model.strip() or "eleven_v4",
        )
    if provider_name in {"cartesia", "cartesia-sonic", "sonic-3.6"}:
        api_key = settings.cartesia_api_key.strip()
        if not api_key:
            return UnavailableSpeechProvider(provider_name="cartesia (API key required)")
        return CartesiaSpeechProvider(
            api_key=api_key,
            model_id=settings.cartesia_model.strip() or "sonic-3.6",
            api_version=settings.cartesia_api_version.strip() or "2026-08-14",
        )
    return UnavailableSpeechProvider(provider_name=provider_name)
