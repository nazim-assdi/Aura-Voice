from uuid import uuid4

from fastapi import APIRouter, File, HTTPException, UploadFile, status
from fastapi.responses import Response
from sqlalchemy import select
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
    project = await session.scalar(
        select(Project).where(Project.id == project_id, Project.owner_id == user.id)
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")
    media_type = file.content_type or "application/octet-stream"
    if not (media_type.startswith("audio/") or media_type in {"application/ogg", "video/webm"}):
        raise HTTPException(status_code=415, detail="Only audio files are accepted.")
    content = await file.read(MAX_AUDIO_BYTES + 1)
    if not content or len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="Audio asset limit is 10 MB.")
    filename = (file.filename or "audio-export").replace("/", "_").replace("\\", "_")[:180]
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
