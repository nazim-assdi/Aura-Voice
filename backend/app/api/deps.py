from datetime import datetime, timezone
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import auth_not_ready, bearer_or_cookie, decode_access_claims
from app.db import get_session
from app.models import AuthSession, User

SessionDep = Annotated[AsyncSession, Depends(get_session)]


async def get_current_user(
    request: Request,
    session: SessionDep,
) -> User:
    if not settings.auth_ready:
        raise auth_not_ready()

    token = bearer_or_cookie(request)
    claims = decode_access_claims(token) if token else None
    if not claims:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "authentication_required", "message": "Please sign in to continue."},
            headers={"WWW-Authenticate": "Bearer"},
        )

    now = datetime.now(timezone.utc)
    auth_session = await session.scalar(
        select(AuthSession).where(
            AuthSession.jti == claims["jti"],
            AuthSession.user_id == claims["sub"],
            AuthSession.revoked_at.is_(None),
            AuthSession.access_expires_at > now,
            AuthSession.refresh_expires_at > now,
        )
    )
    if not auth_session:
        raise HTTPException(
            status_code=401,
            detail={"code": "invalid_session", "message": "Your session has expired. Please sign in again."},
        )

    auth_session.last_used_at = now
    user = await session.scalar(
        select(User).where(User.id == claims["sub"], User.is_active.is_(True))
    )
    if not user:
        raise HTTPException(
            status_code=401,
            detail={"code": "invalid_session", "message": "This account is no longer active."},
        )
    await session.commit()
    request.state.auth_session_id = auth_session.id
    request.state.auth_jti = auth_session.jti
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
