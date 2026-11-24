from __future__ import annotations

from typing import Any

import httpx

from app.engines.models import SpeechVoice


class ElevenLabsError(RuntimeError):
    """Sanitized error returned by the ElevenLabs API adapter."""


class ElevenLabsSpeechProvider:
    """Expressive single-speaker TTS using the ElevenLabs Text to Dialogue API."""

    _BASE_URL = "https://api.elevenlabs.io"
    _DELIVERY_TAGS = {
        "natural": "[conversational]",
        "warm": "[warm, friendly]",
        "storytelling": "[expressive storytelling]",
        "energetic": "[excited, energetic]",
        "calm": "[calm, gentle]",
    }
    _MAX_CHARS = 2000

    def __init__(self, *, api_key: str, model_id: str = "eleven_v4") -> None:
        self._api_key = api_key.strip()
        self._model_id = model_id.strip() or "eleven_v4"

    @property
    def name(self) -> str:
        return "elevenlabs"

    @property
    def is_ready(self) -> bool:
        return bool(self._api_key)

    def _headers(self) -> dict[str, str]:
        return {"xi-api-key": self._api_key, "Accept": "application/json"}

    def _raise_for_status(self, response: httpx.Response) -> None:
        if response.status_code < 400:
            return
        if response.status_code == 401:
            raise ElevenLabsError("ElevenLabs rejected the saved API key. Check the key in Voice Engine settings.")
        if response.status_code == 402:
            raise ElevenLabsError("The ElevenLabs account has no available generation credits. Check its plan and usage.")
        if response.status_code == 429:
            raise ElevenLabsError("ElevenLabs rate limit reached. Wait a moment and retry.")
        message = ""
        try:
            payload = response.json()
            detail = payload.get("detail") if isinstance(payload, dict) else None
            if isinstance(detail, dict):
                message = str(detail.get("message") or detail.get("status") or "")
            elif isinstance(detail, str):
                message = detail
        except (ValueError, TypeError):
            pass
        suffix = f" {message[:240]}" if message else ""
        raise ElevenLabsError(f"ElevenLabs request failed (HTTP {response.status_code}).{suffix}")

    async def list_voices(self, locale: str) -> list[SpeechVoice]:
        language_code = locale.strip().split("-", 1)[0].lower()
        if not language_code:
            return []
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=12.0)) as client:
            response = await client.get(
                f"{self._BASE_URL}/v2/voices",
                headers=self._headers(),
                params={"page_size": 100, "language": language_code, "include_total_count": "false"},
            )
        self._raise_for_status(response)
        payload = response.json()
        rows = payload.get("voices", []) if isinstance(payload, dict) else []
        result: list[SpeechVoice] = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            voice_id = row.get("voice_id")
            if not isinstance(voice_id, str) or not voice_id:
                continue
            labels = row.get("labels") if isinstance(row.get("labels"), dict) else {}
            verified = row.get("verified_languages") if isinstance(row.get("verified_languages"), list) else []
            locale_value = locale
            for language in verified:
                if isinstance(language, dict) and str(language.get("language", "")).lower() == language_code:
                    locale_value = str(language.get("locale") or locale)
                    break
            gender = str(labels.get("gender") or "Voice").strip().title()
            result.append(
                SpeechVoice(
                    id=voice_id,
                    name=str(row.get("name") or "ElevenLabs voice"),
                    locale=locale_value,
                    gender=gender,
                )
            )
        return result

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        voice: str,
        rate: int = 0,
        pitch: int = 0,
        audio_format: str = "mp3",
        delivery: str = "natural",
    ) -> bytes:
        if audio_format != "mp3":
            raise ValueError("The ElevenLabs v4 voice engine currently returns MP3 audio.")
        if not text.strip():
            raise ValueError("The speech script cannot be empty.")
        if len(text) > self._MAX_CHARS:
            raise ValueError("ElevenLabs v4 dialogue supports up to 2,000 characters per request.")
        if not voice.strip():
            raise ValueError("Select an available ElevenLabs voice first.")
        if delivery not in self._DELIVERY_TAGS:
            raise ValueError("Choose a supported speaking style.")

        available = await self.list_voices(language)
        if not any(item.id == voice for item in available):
            raise ValueError("The selected voice is not available for this language in your ElevenLabs account.")

        body: dict[str, Any] = {
            "inputs": [{"text": f"{self._DELIVERY_TAGS[delivery]} {text.strip()}", "voice_id": voice}],
            "model_id": self._model_id,
            "language_code": language.strip().split("-", 1)[0].lower(),
        }
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=15.0)) as client:
            response = await client.post(
                f"{self._BASE_URL}/v1/text-to-dialogue",
                headers={**self._headers(), "Content-Type": "application/json"},
                params={"output_format": "mp3_44100_128"},
                json=body,
            )
        self._raise_for_status(response)
        if not response.content:
            raise ElevenLabsError("ElevenLabs returned an empty audio file. Try again.")
        return response.content
