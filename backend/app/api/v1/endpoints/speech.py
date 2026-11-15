from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from app.api.deps import CurrentUser, SessionDep
from app.core.client_ip import get_client_ip
from app.core.limits import (
    consume_generation_quota,
    enforce_rate_limit,
    refund_generation_quota,
)
from app.engines.registry import get_speech_provider

router = APIRouter()


class SpeechGenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=5000)
    language: str = Field(default="en", min_length=2, max_length=16)
    audio_format: Literal["wav", "mp3"] = "wav"
    voice_profile_id: str | None = Field(default=None, max_length=128)
    speed: float = Field(default=1.0, ge=0.6, le=1.5)
    volume: float = Field(default=1.0, ge=0.5, le=2.0)
    emotion: Literal[
        "neutral", "happy", "excited", "enthusiastic", "content", "peaceful",
        "calm", "grateful", "affectionate", "sympathetic", "curious",
        "angry", "frustrated", "sad", "melancholic", "disappointed",
        "apologetic", "hesitant", "confused", "anxious", "scared",
        "proud", "confident", "skeptical", "contemplative", "determined",
    ] | None = None


def client_bucket(request: Request) -> str:
    host = get_client_ip(request)
    return host[:64]


@router.get("/voices")
async def list_voices(
    request: Request,
    user: CurrentUser,
    session: SessionDep,
    language: str | None = Query(default=None, min_length=2, max_length=16),
    limit: int = Query(default=100, ge=1, le=100),
) -> dict[str, object]:
    await enforce_rate_limit(session, f"voices-user:{user.id}", limit=30)
    await enforce_rate_limit(session, f"voices-ip:{client_bucket(request)}", limit=120)
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "Cartesia is not configured. Add the backend API key.",
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
async def generate_speech(
    payload: SpeechGenerateRequest,
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> Response:
    await enforce_rate_limit(session, f"tts-user:{user.id}", limit=10)
    await enforce_rate_limit(session, f"tts-ip:{client_bucket(request)}", limit=60)

    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "Configure a valid Cartesia API key on the backend.",
            },
        )

    await consume_generation_quota(session, user.id, len(payload.text))
    try:
        audio_bytes = await provider.synthesize(
            text=payload.text,
            language=payload.language,
            audio_format=payload.audio_format,
            voice_profile_id=payload.voice_profile_id,
            speed=payload.speed,
            volume=payload.volume,
            emotion=payload.emotion,
        )
    except ValueError as exc:
        await refund_generation_quota(session, user.id, len(payload.text))
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        await refund_generation_quota(session, user.id, len(payload.text))
        raise HTTPException(
            status_code=502,
            detail={"code": "speech_generation_failed", "message": str(exc)},
        ) from exc
    except Exception:
        await refund_generation_quota(session, user.id, len(payload.text))
        raise

    media_type = "audio/mpeg" if payload.audio_format == "mp3" else "audio/wav"
    return Response(
        content=audio_bytes,
        media_type=media_type,
        headers={
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )
