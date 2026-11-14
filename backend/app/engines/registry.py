from app.core.config import settings
from app.engines.base import SpeechProvider, UnavailableSpeechProvider
from app.engines.cartesia import CartesiaSpeechProvider


def get_speech_provider() -> SpeechProvider:
    """Return the configured provider, failing closed for unknown providers."""
    provider_name = settings.speech_provider.strip().lower() or "none"

    if provider_name == "cartesia":
        provider = CartesiaSpeechProvider()
        if provider.is_ready:
            return provider
        return UnavailableSpeechProvider(provider_name="cartesia")

    # New providers must be added here only after their adapter and tests exist.
    return UnavailableSpeechProvider(provider_name=provider_name)
