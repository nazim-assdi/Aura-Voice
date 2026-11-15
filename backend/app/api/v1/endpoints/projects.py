import json
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import CurrentUser, SessionDep
from app.core.limits import enforce_rate_limit
from app.models import AudioAsset, Project

router = APIRouter(prefix="/projects")


class ProjectCreate(BaseModel):
    name: str = Field(default="Untitled project", min_length=1, max_length=100)
    script: str = Field(default="", max_length=5000)
    language: str = Field(default="en", min_length=2, max_length=16)
    settings: dict[str, object] = Field(default_factory=dict)


class ProjectUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    script: str | None = Field(default=None, max_length=5000)
    language: str | None = Field(default=None, min_length=2, max_length=16)
    settings: dict[str, object] | None = None
    is_archived: bool | None = None


def project_json(project: Project) -> dict[str, object]:
    try:
        options = json.loads(project.settings_json or "{}")
    except ValueError:
        options = {}
    return {
        "id": project.id,
        "name": project.name,
        "script": project.script,
        "language": project.language,
        "settings": options,
        "is_archived": project.is_archived,
        "created_at": project.created_at.isoformat() if project.created_at else None,
        "updated_at": project.updated_at.isoformat() if project.updated_at else None,
    }


@router.get("")
async def list_projects(user: CurrentUser, session: SessionDep) -> dict[str, object]:
    await enforce_rate_limit(session, f"projects:{user.id}", limit=120)
    rows = await session.scalars(
        select(Project)
        .where(Project.owner_id == user.id, Project.is_archived.is_(False))
        .order_by(Project.updated_at.desc())
        .limit(100)
    )
    return {"projects": [project_json(item) for item in rows]}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_project(
    payload: ProjectCreate,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    await enforce_rate_limit(session, f"projects:{user.id}", limit=30)
    project = Project(
        id=str(uuid4()),
        owner_id=user.id,
        name=payload.name.strip(),
        script=payload.script,
        language=payload.language,
        settings_json=json.dumps(payload.settings, ensure_ascii=False),
    )
    session.add(project)
    await session.commit()
    await session.refresh(project)
    return project_json(project)


@router.get("/{project_id}")
async def get_project(
    project_id: str,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    project = await session.scalar(
        select(Project).where(Project.id == project_id, Project.owner_id == user.id)
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")
    assets = await session.scalars(
        select(AudioAsset)
        .where(AudioAsset.project_id == project.id, AudioAsset.owner_id == user.id)
        .order_by(AudioAsset.created_at.desc())
    )
    result = project_json(project)
    result["assets"] = [
        {
            "id": item.id,
            "filename": item.filename,
            "media_type": item.media_type,
            "size_bytes": item.size_bytes,
            "created_at": item.created_at.isoformat() if item.created_at else None,
        }
        for item in assets
    ]
    return result


@router.patch("/{project_id}")
async def update_project(
    project_id: str,
    payload: ProjectUpdate,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    project = await session.scalar(
        select(Project).where(Project.id == project_id, Project.owner_id == user.id)
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")
    values = payload.model_dump(exclude_unset=True)
    for key, value in values.items():
        if key == "settings":
            project.settings_json = json.dumps(value or {}, ensure_ascii=False)
        else:
            setattr(project, key, value)
    await session.commit()
    await session.refresh(project)
    return project_json(project)


@router.delete("/{project_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_project(
    project_id: str,
    user: CurrentUser,
    session: SessionDep,
) -> Response:
    project = await session.scalar(
        select(Project).where(Project.id == project_id, Project.owner_id == user.id)
    )
    if not project:
        raise HTTPException(status_code=404, detail="Project not found.")
    await session.delete(project)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
