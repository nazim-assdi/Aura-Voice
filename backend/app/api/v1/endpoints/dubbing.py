from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field

from app.api.deps import CurrentUser, SessionDep
from app.core.limits import consume_generation_quota, enforce_rate_limit, refund_generation_quota
from app.core.config import settings
from app.engines.registry import get_speech_provider
from app.services.llm import complete_chat

router = APIRouter(prefix="/dubbing")
MAX_UPLOAD_BYTES = 25 * 1024 * 1024


@router.post("/transcribe")
async def transcribe_audio(
    request: Request,
    user: CurrentUser,
    session: SessionDep,
    file: UploadFile = File(...),
    language: str = Form(default="en", min_length=2, max_length=16),
) -> dict[str, object]:
    await enforce_rate_limit(session, f"stt:{user.id}", limit=10)
    host = request.client.host if request.client else "unknown"
    await enforce_rate_limit(session, f"stt-ip:{host[:64]}", limit=40)
    if not settings.cartesia_api_key.strip():
        raise HTTPException(status_code=503, detail={"code": "stt_not_configured", "message": "Configure the Cartesia API key first."})
    media_type = (file.content_type or "").lower().split(";", 1)[0].strip()
    allowed_media_types = {
        "audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4",
        "audio/aac", "audio/ogg", "audio/webm", "audio/flac",
        "audio/x-flac", "application/ogg",
    }
    if media_type not in allowed_media_types:
        raise HTTPException(status_code=415, detail="Unsupported audio format.")
    content = await file.read(MAX_UPLOAD_BYTES + 1)
    if not content or len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Audio upload limit is 25 MB.")
    provider = get_speech_provider()
    if not hasattr(provider, "transcribe"):
        raise HTTPException(status_code=503, detail="Speech-to-text provider is unavailable.")
    try:
        result = await provider.transcribe(
            audio=content,
            filename=(file.filename or "recording.wav"),
            media_type=media_type,
            language=language,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail={"code": "transcription_failed", "message": str(exc)}) from exc
    return result


class TranslateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=20000)
    source_language: str = Field(default="auto", min_length=2, max_length=16)
    target_language: str = Field(min_length=2, max_length=16)


@router.post("/translate")
async def translate_text(
    payload: TranslateRequest,
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, str]:
    await enforce_rate_limit(session, f"translate:{user.id}", limit=10)
    host = request.client.host if request.client else "unknown"
    await enforce_rate_limit(session, f"translate-ip:{host[:64]}", limit=40)
    prompt = (
        f"Translate the supplied script from {payload.source_language} into "
        f"{payload.target_language}. Preserve names, numbers, meaning, tone and paragraph structure. "
        "Return only the translated text. Do not add explanations."
    )
    try:
        translated = await complete_chat(system=prompt, user=payload.text, max_tokens=3000)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail={"code": "translation_unavailable", "message": str(exc)}) from exc
    return {"translated_text": translated, "target_language": payload.target_language}


class DubRenderRequest(BaseModel):
    translated_text: str = Field(min_length=1, max_length=5000)
    target_language: str = Field(min_length=2, max_length=16)
    voice_id: str = Field(min_length=1, max_length=128)
    audio_format: str = Field(default="wav", pattern="^(wav|mp3)$")


@router.post("/render")
async def render_dub(
    payload: DubRenderRequest,
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    await enforce_rate_limit(session, f"dub:{user.id}", limit=10)
    host = request.client.host if request.client else "unknown"
    await enforce_rate_limit(session, f"dub-ip:{host[:64]}", limit=40)
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(status_code=503, detail={"code": "tts_not_configured", "message": "Configure Cartesia before rendering a dub."})
    await consume_generation_quota(session, user.id, len(payload.translated_text))
    try:
        audio = await provider.synthesize(
            text=payload.translated_text,
            language=payload.target_language,
            audio_format=payload.audio_format,
            voice_profile_id=payload.voice_id,
            speed=1.0,
            volume=1.0,
        )
    except (ValueError, RuntimeError) as exc:
        await refund_generation_quota(session, user.id, len(payload.translated_text))
        raise HTTPException(status_code=502, detail={"code": "dub_render_failed", "message": str(exc)}) from exc
    # The caller stores the returned bytes in its owner-scoped project asset endpoint.
    import base64
    return {
        "audio_base64": base64.b64encode(audio).decode("ascii"),
        "media_type": "audio/mpeg" if payload.audio_format == "mp3" else "audio/wav",
        "format": payload.audio_format,
    }
