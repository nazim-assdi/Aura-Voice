from typing import Literal

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel, Field

from app.engines.registry import get_speech_provider

router = APIRouter()


class SpeechGenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=5000)
    language: str = Field(default="en", min_length=2, max_length=16)
    audio_format: Literal["wav"] = "wav"
    voice_profile_id: str | None = Field(default=None, max_length=128)
    speed: float = Field(default=1.0, ge=0.6, le=1.5)


@router.get("/voices")
async def list_voices(
    language: str | None = Query(default=None, min_length=2, max_length=16),
    limit: int = Query(default=100, ge=1, le=100),
) -> dict[str, object]:
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "Cartesia is not configured. Add the API key to the backend environment.",
            },
        )
    try:
        voices = await provider.list_voices(language=language, limit=limit)
    except RuntimeError as exc:
        raise HTTPException(
            status_code=502,
            detail={"code": "voice_catalogue_unavailable", "message": str(exc)},
        ) from exc
    return {"provider": provider.name, "voices": voices}


@router.post("/generate")
async def generate_speech(payload: SpeechGenerateRequest) -> Response:
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "No speech model is configured. Add a valid Cartesia API key to the backend environment.",
            },
        )

    try:
        audio_bytes = await provider.synthesize(
            text=payload.text,
            language=payload.language,
            audio_format=payload.audio_format,
            voice_profile_id=payload.voice_profile_id,
            speed=payload.speed,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(
            status_code=502,
            detail={"code": "speech_generation_failed", "message": str(exc)},
        ) from exc

    return Response(
        content=audio_bytes,
        media_type="audio/wav",
        headers={"Cache-Control": "no-store"},
    )
