from __future__ import annotations

import asyncio
import time
from collections import defaultdict, deque
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from app.engines.registry import get_speech_provider

router = APIRouter()
_request_times: dict[str, deque[float]] = defaultdict(deque)


class SpeechGenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=5000)
    language: str = Field(default="bn-BD", min_length=2, max_length=16)
    voice: str = Field(default="bn-BD-NabanitaNeural", min_length=4, max_length=128)
    rate: int = Field(default=0, ge=-50, le=50)
    pitch: int = Field(default=0, ge=-50, le=50)
    delivery: Literal["natural", "warm", "storytelling", "energetic", "calm"] = "natural"
    audio_format: Literal["mp3"] = "mp3"


@router.get("/voices")
async def list_voices(
    locale: str = Query(default="bn-BD", min_length=2, max_length=16),
) -> list[dict[str, str]]:
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "No neural speech provider is configured.",
            },
        )
    try:
        voices = await asyncio.wait_for(provider.list_voices(locale), timeout=30)
    except asyncio.TimeoutError as error:
        raise HTTPException(
            status_code=504,
            detail={
                "code": "voice_list_timeout",
                "message": "The online voice service did not respond in time.",
            },
        ) from error
    except Exception as error:
        raise HTTPException(
            status_code=502,
            detail={
                "code": "voice_list_failed",
                "message": "Could not load voices. Check the backend internet connection.",
            },
        ) from error
    return [voice.model_dump() for voice in voices]


def _enforce_generation_limit(request: Request) -> None:
    client_host = request.client.host if request.client else "unknown"
    now = time.monotonic()
    bucket = _request_times[client_host]
    while bucket and now - bucket[0] >= 60:
        bucket.popleft()
    if len(bucket) >= 8:
        raise HTTPException(
            status_code=429,
            detail={
                "code": "speech_rate_limit",
                "message": "The speech generation limit is 8 requests per minute per client.",
            },
        )
    bucket.append(now)


@router.post("/generate")
async def generate_speech(payload: SpeechGenerateRequest, request: Request) -> Response:
    _enforce_generation_limit(request)
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "speech_engine_not_configured",
                "message": "No neural speech provider is configured.",
            },
        )

    try:
        audio_bytes = await asyncio.wait_for(
            provider.synthesize(
                text=payload.text,
                language=payload.language,
                voice=payload.voice,
                rate=payload.rate,
                pitch=payload.pitch,
                audio_format=payload.audio_format,
                delivery=payload.delivery,
            ),
            timeout=120,
        )
    except asyncio.TimeoutError as error:
        raise HTTPException(
            status_code=504,
            detail={
                "code": "speech_generation_timeout",
                "message": "Speech generation timed out. Try a shorter script or retry.",
            },
        ) from error
    except ValueError as error:
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_speech_request", "message": str(error)},
        ) from error
    except RuntimeError as error:
        raise HTTPException(
            status_code=502,
            detail={"code": "speech_generation_failed", "message": str(error)},
        ) from error
    except Exception as error:
        raise HTTPException(
            status_code=502,
            detail={
                "code": "speech_generation_failed",
                "message": "The online neural voice service could not generate this audio. Check internet access and retry.",
            },
        ) from error

    if not audio_bytes:
        raise HTTPException(
            status_code=502,
            detail={
                "code": "empty_speech_result",
                "message": "The speech service returned an empty audio file.",
            },
        )
    return Response(
        content=audio_bytes,
        media_type="audio/mpeg",
        headers={
            "Cache-Control": "no-store",
            "Content-Disposition": 'inline; filename="aura-voice.mp3"',
        },
    )
