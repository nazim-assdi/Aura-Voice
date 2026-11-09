from typing import Literal

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

from app.engines.registry import get_speech_provider

router = APIRouter()


class SpeechGenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=5000)
    language: str = Field(default="en", min_length=2, max_length=16)
    audio_format: Literal["wav", "mp3", "ogg", "flac"] = "wav"
    voice_profile_id: str | None = None


@router.post("/generate")
async def generate_speech(payload: SpeechGenerateRequest) -> Response:
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "No speech model is configured. Add and validate a licensed provider first.",
            },
        )

    audio_bytes = await provider.synthesize(
        text=payload.text,
        language=payload.language,
        audio_format=payload.audio_format,
        voice_profile_id=payload.voice_profile_id,
    )
    media_types = {
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "flac": "audio/flac",
    }
    return Response(
        content=audio_bytes,
        media_type=media_types[payload.audio_format],
        headers={"Cache-Control": "no-store"},
    )
