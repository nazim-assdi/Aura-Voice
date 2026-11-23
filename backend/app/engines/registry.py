from app.core.config import settings
from app.engines.base import SpeechProvider, UnavailableSpeechProvider
from app.engines.edge_tts import get_edge_tts_provider


def get_speech_provider() -> SpeechProvider:
    """Resolve a configured speech adapter; unknown names fail closed."""
    provider_name = settings.speech_provider.strip().lower() or "none"
    if provider_name in {"edge", "edge-tts"}:
        return get_edge_tts_provider()
    return UnavailableSpeechProvider(provider_name=provider_name)
