from __future__ import annotations

from functools import lru_cache

import edge_tts

from app.engines.models import SpeechVoice


class EdgeTtsSpeechProvider:
    """Online neural speech adapter using the edge-tts community client.

    This provider needs outbound internet access. It is not an offline model.
    """

    @property
    def name(self) -> str:
        return "edge-tts"

    @property
    def is_ready(self) -> bool:
        return True

    async def list_voices(self, locale: str) -> list[SpeechVoice]:
        normalized_locale = locale.strip().lower()
        if not normalized_locale:
            return []
        voices = await edge_tts.list_voices()
        result: list[SpeechVoice] = []
        for voice in voices:
            voice_locale = str(voice.get("Locale", ""))
            if voice_locale.lower() != normalized_locale:
                continue
            short_name = voice.get("ShortName")
            if not isinstance(short_name, str) or not short_name:
                continue
            result.append(
                SpeechVoice(
                    id=short_name,
                    name=str(voice.get("FriendlyName") or short_name),
                    locale=voice_locale,
                    gender=str(voice.get("Gender") or "Unknown"),
                )
            )
        return sorted(result, key=lambda item: (item.gender, item.name))

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
        if audio_format != "mp3":
            raise ValueError("The online neural voice provider currently returns MP3 audio.")
        if not text.strip():
            raise ValueError("The speech script cannot be empty.")
        if not voice.strip():
            raise ValueError("Select a neural voice first.")
        if not -50 <= rate <= 50 or not -50 <= pitch <= 50:
            raise ValueError("Speech rate and pitch must be between -50 and +50.")

        available = await self.list_voices(language)
        if not any(item.id == voice for item in available):
            raise ValueError("The selected voice is not available for this language.")

        communicate = edge_tts.Communicate(
            text,
            voice,
            rate=f"{rate:+d}%",
            pitch=f"{pitch:+d}Hz",
        )
        audio = bytearray()
        async for packet in communicate.stream():
            if packet.get("type") == "audio":
                audio.extend(packet.get("data", b""))
        if not audio:
            raise RuntimeError("The neural speech service returned no audio.")
        return bytes(audio)


@lru_cache(maxsize=1)
def get_edge_tts_provider() -> EdgeTtsSpeechProvider:
    return EdgeTtsSpeechProvider()
