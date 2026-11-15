from uuid import uuid4

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.api.deps import CurrentUser, SessionDep
from app.engines.registry import get_speech_provider
from app.models import VoiceFavorite

router = APIRouter(prefix="/voices")


class FavoriteRequest(BaseModel):
    voice_id: str = Field(min_length=1, max_length=128)
    voice_name: str = Field(min_length=1, max_length=120)
    language: str = Field(default="en", min_length=2, max_length=16)


@router.get("")
async def list_voices(
    user: CurrentUser,
    language: str | None = None,
) -> dict[str, object]:
    provider = get_speech_provider()
    if not provider.is_ready:
        raise HTTPException(
            status_code=503,
            detail={"code": "speech_engine_not_configured", "message": "Configure the Cartesia API key on the backend."},
        )
    try:
        voices = await provider.list_voices(language=language, limit=100)
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"provider": provider.name, "voices": voices}


@router.get("/favorites")
async def favorites(user: CurrentUser, session: SessionDep) -> dict[str, object]:
    rows = await session.scalars(
        select(VoiceFavorite)
        .where(VoiceFavorite.owner_id == user.id)
        .order_by(VoiceFavorite.created_at.desc())
    )
    return {
        "favorites": [
            {"voice_id": item.voice_id, "voice_name": item.voice_name, "language": item.language}
            for item in rows
        ]
    }


@router.post("/favorites")
async def add_favorite(
    payload: FavoriteRequest,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    existing = await session.scalar(
        select(VoiceFavorite).where(
            VoiceFavorite.owner_id == user.id,
            VoiceFavorite.voice_id == payload.voice_id,
        )
    )
    if existing:
        return {"ok": True, "voice_id": existing.voice_id}
    session.add(VoiceFavorite(
        id=str(uuid4()),
        owner_id=user.id,
        voice_id=payload.voice_id,
        voice_name=payload.voice_name,
        language=payload.language,
    ))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
    return {"ok": True, "voice_id": payload.voice_id}


@router.delete("/favorites/{voice_id}")
async def remove_favorite(
    voice_id: str,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, bool]:
    favorite = await session.scalar(
        select(VoiceFavorite).where(
            VoiceFavorite.owner_id == user.id,
            VoiceFavorite.voice_id == voice_id,
        )
    )
    if favorite:
        await session.delete(favorite)
        await session.commit()
    return {"ok": True}
