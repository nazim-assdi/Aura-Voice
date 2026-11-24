from __future__ import annotations

from typing import Any

import httpx

from app.engines.models import SpeechVoice


class CartesiaError(RuntimeError):
    """Sanitized error returned by the Cartesia API adapter."""


class CartesiaSpeechProvider:
    """Cartesia Sonic 3.6 speech synthesis with account voice discovery."""

    _BASE_URL = "https://api.cartesia.ai"
    _API_VERSION = "2026-08-14"
    _MODEL_ID = "sonic-3.6"
    _EMOTIONS = {
        "warm": "content",
        "storytelling": "curious",
        "energetic": "excited",
        "calm": "calm",
    }

    def __init__(
        self,
        *,
        api_key: str,
        model_id: str = _MODEL_ID,
        api_version: str = _API_VERSION,
    ) -> None:
        self._api_key = api_key.strip()
        self._model_id = model_id.strip() or self._MODEL_ID
        self._api_version = api_version.strip() or self._API_VERSION

    @property
    def name(self) -> str:
        return "cartesia"

    @property
    def is_ready(self) -> bool:
        return bool(self._api_key)

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._api_key}",
            "Cartesia-Version": self._api_version,
            "Accept": "application/json",
        }

    def _raise_for_status(self, response: httpx.Response) -> None:
        if response.status_code < 400:
            return
        if response.status_code == 401:
            raise CartesiaError("Cartesia rejected the saved API key. Check it in Voice Engine settings.")
        if response.status_code == 402:
            raise CartesiaError("The Cartesia account has no available credits. Check its plan and usage.")
        if response.status_code == 429:
            raise CartesiaError("Cartesia rate limit reached. Wait a moment and retry.")

        message = ""
        try:
            payload = response.json()
            if isinstance(payload, dict):
                message = str(payload.get("message") or payload.get("title") or payload.get("error") or "")
        except (ValueError, TypeError):
            pass
        suffix = f" {message[:240]}" if message else ""
        raise CartesiaError(f"Cartesia request failed (HTTP {response.status_code}).{suffix}")

    async def list_voices(self, locale: str) -> list[SpeechVoice]:
        language = locale.strip()
        if not language:
            return []

        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=12.0)) as client:
            response = await client.get(
                f"{self._BASE_URL}/voices",
                headers=self._headers(),
                params={"limit": 100, "language": language},
            )
        self._raise_for_status(response)

        payload = response.json()
        rows = payload.get("data", []) if isinstance(payload, dict) else []
        result: list[SpeechVoice] = []
        requested_base_language = language.split("-", 1)[0].lower()

        for row in rows:
            if not isinstance(row, dict):
                continue
            voice_id = row.get("id")
            if not isinstance(voice_id, str) or not voice_id:
                continue

            accents = row.get("accents") if isinstance(row.get("accents"), list) else []
            voice_locale = language
            for accent in accents:
                if not isinstance(accent, dict):
                    continue
                accent_locale = str(accent.get("locale") or "")
                if accent_locale.lower() == language.lower():
                    voice_locale = accent_locale
                    break
                if accent_locale.split("-", 1)[0].lower() == requested_base_language:
                    voice_locale = accent_locale

            gender_value = str(row.get("gender") or "gender_neutral").lower()
            gender = {
                "feminine": "Female",
                "masculine": "Male",
                "gender_neutral": "Gender neutral",
            }.get(gender_value, "Voice")

            result.append(
                SpeechVoice(
                    id=voice_id,
                    name=str(row.get("name") or "Cartesia voice"),
                    locale=voice_locale,
                    gender=gender,
                )
            )
        return sorted(result, key=lambda item: (item.gender, item.name.casefold()))

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
            raise ValueError("Cartesia currently returns MP3 audio from Aura Voice.")
        if not text.strip():
            raise ValueError("The speech script cannot be empty.")
        if not voice.strip():
            raise ValueError("Select an available Cartesia voice first.")
        if not -50 <= rate <= 50:
            raise ValueError("Speech rate must be between -50 and +50.")
        if delivery not in {"natural", "warm", "storytelling", "energetic", "calm"}:
            raise ValueError("Choose a supported speaking style.")

        # Confirm the selected voice belongs to the requested language.
        available = await self.list_voices(language)
        if not any(item.id == voice for item in available):
            raise ValueError("The selected Cartesia voice is not available for this language.")

        generation_config: dict[str, Any] = {
            "speed": round(max(0.6, min(1.5, 1.0 + rate / 100)), 2),
            "volume": 1.0,
        }
        # Cartesia emotion tags are currently supported only for English.
        # For Bengali and other languages, let Sonic infer natural emotion
        # from punctuation, wording and context; pace remains adjustable.
        if language.strip().split("-", 1)[0].lower() == "en":
            emotion = self._EMOTIONS.get(delivery)
            if emotion:
                generation_config["emotion"] = emotion

        body = {
            "model_id": self._model_id,
            "transcript": text.strip(),
            "voice": voice,
            "language": language.strip(),
            "normalization": "auto",
            "output_format": {
                "container": "mp3",
                "sample_rate": 44100,
                "bit_rate": 128000,
            },
            "generation_config": generation_config,
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=15.0)) as client:
            response = await client.post(
                f"{self._BASE_URL}/tts/bytes",
                headers={**self._headers(), "Content-Type": "application/json"},
                json=body,
            )
        self._raise_for_status(response)
        if not response.content:
            raise CartesiaError("Cartesia returned an empty audio file. Try again.")
        return response.content
