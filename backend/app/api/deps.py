from typing import Annotated

from fastapi import Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import auth_not_ready, bearer_or_cookie, decode_access_token
from app.db import get_session
from app.models import User

SessionDep = Annotated[AsyncSession, Depends(get_session)]


async def get_current_user(
    request: Request,
    session: SessionDep,
) -> User:
    if not settings.auth_ready:
        raise auth_not_ready()
    token = bearer_or_cookie(request)
    subject = decode_access_token(token) if token else None
    if not subject:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "authentication_required", "message": "Please sign in to continue."},
            headers={"WWW-Authenticate": "Bearer"},
        )
    user = await session.scalar(select(User).where(User.id == subject, User.is_active.is_(True)))
    if not user:
        raise HTTPException(status_code=401, detail={"code": "invalid_session", "message": "Please sign in again."})
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
