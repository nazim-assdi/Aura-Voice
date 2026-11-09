from typing import Protocol


class SpeechProvider(Protocol):
    @property
    def name(self) -> str: ...

    @property
    def is_ready(self) -> bool: ...

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        audio_format: str,
        voice_profile_id: str | None = None,
    ) -> bytes: ...


class UnavailableSpeechProvider:
    """Safe default provider; it never fabricates audio output."""

    def __init__(self, provider_name: str = "none") -> None:
        self._provider_name = provider_name

    @property
    def name(self) -> str:
        return self._provider_name

    @property
    def is_ready(self) -> bool:
        return False

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        audio_format: str,
        voice_profile_id: str | None = None,
    ) -> bytes:
        raise RuntimeError("Speech provider is unavailable. Configure a real provider first.")
