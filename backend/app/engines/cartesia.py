import httpx

from app.core.config import settings


class CartesiaSpeechProvider:
    """Cartesia Sonic text-to-speech adapter.

    The API key is only read by the backend and is never returned to clients.
    """

    BASE_URL = "https://api.cartesia.ai"

    @property
    def name(self) -> str:
        return "cartesia"

    @property
    def is_ready(self) -> bool:
        return bool(settings.cartesia_api_key.strip())

    def _headers(self) -> dict[str, str]:
        return {
            "X-API-Key": settings.cartesia_api_key,
            "Cartesia-Version": settings.cartesia_version,
            "Content-Type": "application/json",
        }

    async def synthesize(
        self,
        *,
        text: str,
        language: str,
        audio_format: str,
        voice_profile_id: str | None = None,
        speed: float = 1.0,
        volume: float = 1.0,
        emotion: str | None = None,
    ) -> bytes:
        if not self.is_ready:
            raise RuntimeError("Cartesia is not configured. Add AURA_CARTESIA_API_KEY to the backend environment.")
        if audio_format not in {"wav", "mp3"}:
            raise ValueError("Cartesia output must be WAV or MP3.")

        voice_id = (voice_profile_id or settings.cartesia_voice_id).strip()
        if not voice_id:
            raise RuntimeError("No Cartesia voice is configured. Set AURA_CARTESIA_VOICE_ID.")

        payload = {
            "model_id": settings.cartesia_model_id,
            "transcript": text,
            "voice": {"id": voice_id},
            "language": language,
            "output_format": (
                {
                    "container": "mp3",
                    "sample_rate": 44100,
                    "bit_rate": 128000,
                }
                if audio_format == "mp3"
                else {
                    "container": "wav",
                    "encoding": "pcm_s16le",
                    "sample_rate": 44100,
                }
            ),
            "normalization": "auto",
            "generation_config": {
                "speed": speed,
                "volume": volume,
                **({"emotion": emotion} if emotion else {}),
            },
        }

        try:
            async with httpx.AsyncClient(timeout=settings.cartesia_timeout_seconds) as client:
                response = await client.post(
                    f"{self.BASE_URL}/tts/bytes",
                    headers=self._headers(),
                    json=payload,
                )
        except httpx.TimeoutException as exc:
            raise RuntimeError("Cartesia timed out while generating speech. Please try again.") from exc
        except httpx.RequestError as exc:
            raise RuntimeError("Could not connect to Cartesia. Check the backend network connection.") from exc

        if not response.is_success:
            try:
                error_data = response.json()
                message = error_data.get("message") or error_data.get("error") or "Request rejected"
            except ValueError:
                message = "Request rejected"
            raise RuntimeError(f"Cartesia returned HTTP {response.status_code}: {str(message)[:240]}")

        if not response.content:
            raise RuntimeError("Cartesia returned an empty audio response.")
        return response.content

    async def transcribe(
        self,
        *,
        audio: bytes,
        filename: str,
        media_type: str,
        language: str,
    ) -> dict[str, object]:
        if not self.is_ready:
            raise RuntimeError("Cartesia is not configured. Add AURA_CARTESIA_API_KEY.")
        if len(audio) > 25 * 1024 * 1024:
            raise ValueError("Audio uploads are limited to 25 MB.")
        try:
            async with httpx.AsyncClient(timeout=settings.cartesia_timeout_seconds * 4) as client:
                response = await client.post(
                    f"{self.BASE_URL}/stt",
                    headers={
                        "Authorization": f"Bearer {settings.cartesia_api_key}",
                        "Cartesia-Version": settings.cartesia_version,
                    },
                    data={"model": settings.cartesia_stt_model_id, "language": language},
                    files={"file": (filename, audio, media_type)},
                )
        except httpx.TimeoutException as exc:
            raise RuntimeError("Cartesia transcription timed out.") from exc
        except httpx.RequestError as exc:
            raise RuntimeError("Could not connect to Cartesia STT.") from exc
        if not response.is_success:
            raise RuntimeError(f"Cartesia STT returned HTTP {response.status_code}.")
        try:
            payload = response.json()
        except ValueError as exc:
            raise RuntimeError("Cartesia returned an invalid transcription response.") from exc
        return {
            "text": payload.get("text", ""),
            "language": payload.get("language", language),
            "duration": payload.get("duration"),
            "words": payload.get("words", []),
        }

    async def list_voices(
        self,
        *,
        language: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, object]]:
        if not self.is_ready:
            raise RuntimeError("Cartesia is not configured. Add AURA_CARTESIA_API_KEY to the backend environment.")

        params: dict[str, str | int] = {"limit": max(1, min(limit, 100))}
        if language:
            params["language"] = language

        try:
            async with httpx.AsyncClient(timeout=settings.cartesia_timeout_seconds) as client:
                response = await client.get(
                    f"{self.BASE_URL}/voices",
                    headers=self._headers(),
                    params=params,
                )
        except httpx.TimeoutException as exc:
            raise RuntimeError("Cartesia voice catalogue request timed out.") from exc
        except httpx.RequestError as exc:
            raise RuntimeError("Could not connect to the Cartesia voice catalogue.") from exc

        if not response.is_success:
            raise RuntimeError(f"Cartesia voice catalogue returned HTTP {response.status_code}.")

        try:
            payload = response.json()
        except ValueError as exc:
            raise RuntimeError("Cartesia returned an invalid voice catalogue response.") from exc

        voices = payload.get("data", []) if isinstance(payload, dict) else []
        return [
            {
                "id": voice.get("id"),
                "name": voice.get("name") or "Unnamed voice",
                "language": voice.get("language"),
                "tagline": voice.get("tagline") or "",
                "gender": voice.get("gender"),
            }
            for voice in voices
            if isinstance(voice, dict) and voice.get("id")
        ]
