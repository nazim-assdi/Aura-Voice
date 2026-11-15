from uuid import uuid4

from fastapi import APIRouter, File, HTTPException, UploadFile, status
from fastapi.responses import Response
from sqlalchemy import select
from app.core.limits import enforce_rate_limit
from app.api.deps import CurrentUser, SessionDep
from app.models import AudioAsset, Project

router = APIRouter(prefix="/projects")
MAX_AUDIO_BYTES = 10 * 1024 * 1024


@router.post("/{project_id}/assets", status_code=status.HTTP_201_CREATED)
async def upload_audio_asset(
    project_id: str,
    user: CurrentUser,
    session: SessionDep,
    file: UploadFile = File(...),
) -> dict[str, object]:
    await enforce_rate_limit(session, f"asset-upload:{user.id}", limit=20, window_seconds=3600)
    project = await session.scalar(
        select(Project).where(Project.id == project_id, Project.owner_id == user.id)
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")
    media_type = (file.content_type or "").lower().split(";", 1)[0].strip()
    allowed_media_types = {
        "audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4",
        "audio/aac", "audio/ogg", "audio/webm", "audio/flac",
        "audio/x-flac", "application/ogg",
    }
    if media_type not in allowed_media_types:
        raise HTTPException(status_code=415, detail="Unsupported audio format.")
    content = await file.read(MAX_AUDIO_BYTES + 1)
    if not content or len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="Audio asset limit is 10 MB.")
    raw_filename = (file.filename or "audio-export").replace("/", "_").replace("\\", "_")
    filename = "".join(char for char in raw_filename if char.isalnum() or char in " ._-()").strip()[:120] or "audio-export"
    asset = AudioAsset(
        id=str(uuid4()),
        project_id=project.id,
        owner_id=user.id,
        filename=filename,
        media_type=media_type,
        size_bytes=len(content),
        content=content,
    )
    session.add(asset)
    await session.commit()
    return {
        "id": asset.id,
        "filename": asset.filename,
        "media_type": asset.media_type,
        "size_bytes": asset.size_bytes,
    }


@router.get("/{project_id}/assets/{asset_id}")
async def download_audio_asset(
    project_id: str,
    asset_id: str,
    user: CurrentUser,
    session: SessionDep,
) -> Response:
    await enforce_rate_limit(session, f"asset-download:{user.id}", limit=120)
    asset = await session.scalar(
        select(AudioAsset).where(
            AudioAsset.id == asset_id,
            AudioAsset.project_id == project_id,
            AudioAsset.owner_id == user.id,
        )
    )
    if not asset:
        raise HTTPException(status_code=404, detail="Audio asset not found.")
    return Response(
        content=asset.content,
        media_type=asset.media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{asset.filename}"',
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.delete("/{project_id}/assets/{asset_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_audio_asset(
    project_id: str,
    asset_id: str,
    user: CurrentUser,
    session: SessionDep,
) -> Response:
    await enforce_rate_limit(session, f"asset-delete:{user.id}", limit=60)
    asset = await session.scalar(
        select(AudioAsset).where(
            AudioAsset.id == asset_id,
            AudioAsset.project_id == project_id,
            AudioAsset.owner_id == user.id,
        )
    )
    if not asset:
        raise HTTPException(status_code=404, detail="Audio asset not found.")
    await session.delete(asset)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
