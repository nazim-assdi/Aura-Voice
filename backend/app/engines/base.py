from typing import Protocol

from app.engines.models import SpeechVoice


class SpeechProvider(Protocol):
    @property
    def name(self) -> str: ...

    @property
    def is_ready(self) -> bool: ...

    async def list_voices(self, locale: str) -> list[SpeechVoice]: ...

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        voice: str,
        rate: int = 0,
        pitch: int = 0,
        audio_format: str = "mp3",
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

    async def list_voices(self, locale: str) -> list[SpeechVoice]:
        return []

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        voice: str,
        rate: int = 0,
        pitch: int = 0,
        audio_format: str = "mp3",
    ) -> bytes:
        raise RuntimeError("Speech provider is unavailable. Configure a real provider first.")
