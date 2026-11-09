from app.core.config import settings
from app.engines.base import SpeechProvider, UnavailableSpeechProvider


def get_speech_provider() -> SpeechProvider:
    """Return a provider adapter; unregistered names fail closed."""
    provider_name = settings.speech_provider.strip() or "none"
    # Register a model here only after license review, startup checks,
    # and a successful inference smoke test.
    return UnavailableSpeechProvider(provider_name=provider_name)
