from datetime import datetime, timedelta, timezone
import hashlib
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.exc import IntegrityError

from app.api.deps import CurrentUser, SessionDep
from app.core.config import settings
from app.core.limits import enforce_rate_limit
from app.core.security import (
    auth_not_ready,
    bearer_or_cookie,
    create_access_token,
    decode_access_claims,
    hash_password,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)
from app.models import (
    AudioAsset,
    AuthSession,
    FeatureUsageBucket,
    Project,
    UsageBucket,
    User,
    VoiceFavorite,
)

router = APIRouter(prefix="/auth")
SESSION_REFRESH_DAYS = 30

# A startup-generated dummy hash keeps unknown-account login attempts expensive too.
DUMMY_PASSWORD_HASH = hash_password("aura-voice-dummy-password-never-used")


class RegisterRequest(BaseModel):
    email: str = Field(min_length=5, max_length=320)
    display_name: str = Field(min_length=2, max_length=80)
    password: str = Field(min_length=10, max_length=128)


class LoginRequest(BaseModel):
    email: str = Field(min_length=5, max_length=320)
    password: str = Field(min_length=1, max_length=128)


class RefreshRequest(BaseModel):
    refresh_token: str | None = Field(default=None, min_length=20, max_length=256)


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=10, max_length=128)


class AccountDeleteRequest(BaseModel):
    password: str = Field(min_length=1, max_length=128)


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    email: str
    display_name: str
    plan: str


def normalize_email(value: str) -> str:
    value = value.strip().lower()
    if len(value) > 320 or value.count("@") != 1:
        raise HTTPException(status_code=422, detail="Enter a valid email address.")
    local, domain = value.rsplit("@", 1)
    if not local or "." not in domain or domain.startswith(".") or domain.endswith("."):
        raise HTTPException(status_code=422, detail="Enter a valid email address.")
    return value


def _cookie_options() -> dict[str, object]:
    return {
        "httponly": True,
        "secure": settings.secure_cookies,
        "samesite": "none" if settings.secure_cookies else "lax",
        "path": "/",
    }


def set_session_cookies(response: Response, access_token: str, refresh_token: str) -> None:
    options = _cookie_options()
    response.set_cookie(
        key="aura_session",
        value=access_token,
        max_age=settings.access_token_minutes * 60,
        **options,
    )
    response.set_cookie(
        key="aura_refresh",
        value=refresh_token,
        max_age=SESSION_REFRESH_DAYS * 24 * 60 * 60,
        **options,
    )


def set_mobile_session_headers(response: Response, request: Request, access_token: str, refresh_token: str) -> None:
    if request.headers.get("x-client-type", "").lower() == "mobile":
        response.headers["X-Aura-Access-Token"] = access_token
        response.headers["X-Aura-Refresh-Token"] = refresh_token


async def create_user_session(
    *,
    user: User,
    request: Request,
    response: Response,
    session: SessionDep,
) -> None:
    now = datetime.now(timezone.utc)
    jti = str(uuid4())
    refresh_token = new_refresh_token()
    access_token = create_access_token(user.id, jti=jti)
    auth_session = AuthSession(
        id=str(uuid4()),
        user_id=user.id,
        jti=jti,
        refresh_token_hash=hash_refresh_token(refresh_token),
        access_expires_at=now + timedelta(minutes=settings.access_token_minutes),
        refresh_expires_at=now + timedelta(days=SESSION_REFRESH_DAYS),
        ip_address=request.client.host[:64] if request.client else None,
        user_agent=request.headers.get("user-agent", "")[:300],
        created_at=now,
        last_used_at=now,
    )
    session.add(auth_session)
    await session.commit()
    set_session_cookies(response, access_token, refresh_token)
    set_mobile_session_headers(response, request, access_token, refresh_token)


def clear_session_cookies(response: Response) -> None:
    options = _cookie_options()
    response.delete_cookie("aura_session", **options)
    response.delete_cookie("aura_refresh", **options)


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: RegisterRequest,
    request: Request,
    response: Response,
    session: SessionDep,
) -> User:
    if not settings.auth_ready:
        raise auth_not_ready()
    await enforce_rate_limit(
        session,
        f"register:{request.client.host if request.client else 'unknown'}",
        limit=5,
        window_seconds=3600,
    )
    email = normalize_email(payload.email)
    existing = await session.scalar(select(User).where(func.lower(User.email) == email))
    if existing:
        raise HTTPException(
            status_code=409,
            detail={"code": "email_in_use", "message": "An account with this email already exists."},
        )
    user = User(
        id=str(uuid4()),
        email=email,
        display_name=payload.display_name.strip(),
        password_hash=hash_password(payload.password),
    )
    session.add(user)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=409,
            detail={"code": "email_in_use", "message": "An account with this email already exists."},
        ) from exc
    await session.refresh(user)
    await create_user_session(user=user, request=request, response=response, session=session)
    return user


@router.post("/login", response_model=UserResponse)
async def login(
    payload: LoginRequest,
    request: Request,
    response: Response,
    session: SessionDep,
) -> User:
    if not settings.auth_ready:
        raise auth_not_ready()
    await enforce_rate_limit(
        session,
        f"login:{request.client.host if request.client else 'unknown'}",
        limit=12,
        window_seconds=300,
    )
    email = normalize_email(payload.email)
    email_digest = hashlib.sha256(email.encode("utf-8")).hexdigest()
    await enforce_rate_limit(
        session,
        f"login-email:{email_digest}",
        limit=10,
        window_seconds=900,
    )
    user = await session.scalar(select(User).where(func.lower(User.email) == email))
    candidate_hash = user.password_hash if user else DUMMY_PASSWORD_HASH
    valid_password = verify_password(payload.password, candidate_hash)
    if not user or not valid_password or not user.is_active:
        raise HTTPException(
            status_code=401,
            detail={"code": "invalid_credentials", "message": "Email or password is incorrect."},
        )
    await create_user_session(user=user, request=request, response=response, session=session)
    return user


@router.post("/refresh")
async def refresh_session(
    payload: RefreshRequest,
    request: Request,
    response: Response,
    session: SessionDep,
) -> dict[str, bool]:
    if not settings.auth_ready:
        raise auth_not_ready()
    await enforce_rate_limit(
        session,
        f"refresh:{request.client.host if request.client else 'unknown'}",
        limit=30,
        window_seconds=300,
    )
    refresh_token = request.cookies.get("aura_refresh") or payload.refresh_token
    if not refresh_token:
        clear_session_cookies(response)
        raise HTTPException(status_code=401, detail={"code": "refresh_required", "message": "Please sign in again."})

    now = datetime.now(timezone.utc)
    stored_hash = hash_refresh_token(refresh_token)
    auth_session = await session.scalar(
        select(AuthSession).where(
            AuthSession.refresh_token_hash == stored_hash,
            AuthSession.revoked_at.is_(None),
            AuthSession.refresh_expires_at > now,
        )
    )
    if not auth_session:
        clear_session_cookies(response)
        raise HTTPException(status_code=401, detail={"code": "refresh_invalid", "message": "Your session has expired. Please sign in again."})

    user = await session.scalar(
        select(User).where(User.id == auth_session.user_id, User.is_active.is_(True))
    )
    if not user:
        auth_session.revoked_at = now
        await session.commit()
        clear_session_cookies(response)
        raise HTTPException(status_code=401, detail={"code": "account_inactive", "message": "This account is no longer active."})

    next_jti = str(uuid4())
    next_refresh = new_refresh_token()
    access_token = create_access_token(user.id, jti=next_jti)
    auth_session.jti = next_jti
    auth_session.refresh_token_hash = hash_refresh_token(next_refresh)
    auth_session.access_expires_at = now + timedelta(minutes=settings.access_token_minutes)
    auth_session.refresh_expires_at = now + timedelta(days=SESSION_REFRESH_DAYS)
    auth_session.last_used_at = now
    await session.commit()
    set_session_cookies(response, access_token, next_refresh)
    set_mobile_session_headers(response, request, access_token, next_refresh)
    return {"ok": True}


@router.get("/me", response_model=UserResponse)
async def me(user: CurrentUser) -> User:
    return user


@router.get("/usage")
async def usage(user: CurrentUser, session: SessionDep) -> dict[str, int | str]:
    period = datetime.now(timezone.utc).date().isoformat()
    bucket = await session.scalar(
        select(UsageBucket).where(
            UsageBucket.owner_id == user.id,
            UsageBucket.period_key == period,
        )
    )
    feature_rows = await session.scalars(
        select(FeatureUsageBucket).where(
            FeatureUsageBucket.owner_id == user.id,
            FeatureUsageBucket.period_key == period,
        )
    )
    feature_usage = {item.feature: item.request_count for item in feature_rows}
    audio_storage = await session.scalar(
        select(func.coalesce(func.sum(AudioAsset.size_bytes), 0)).where(
            AudioAsset.owner_id == user.id
        )
    )
    project_count = await session.scalar(
        select(func.count(Project.id)).where(
            Project.owner_id == user.id,
            Project.is_archived.is_(False),
        )
    )
    return {
        "plan": user.plan,
        "period": period,
        "generations_today": bucket.generation_count if bucket else 0,
        "characters_today": bucket.character_count if bucket else 0,
        "daily_generation_limit": 50,
        "daily_character_limit": 50000,
        "transcriptions_today": feature_usage.get("transcription", 0),
        "daily_transcription_limit": 20,
        "translations_today": feature_usage.get("translation", 0),
        "daily_translation_limit": 30,
        "conversations_today": feature_usage.get("conversation", 0),
        "daily_conversation_limit": 60,
        "audio_storage_bytes": int(audio_storage or 0),
        "audio_storage_limit_bytes": 100 * 1024 * 1024,
        "active_projects": int(project_count or 0),
        "active_project_limit": 50,
    }


@router.post("/logout")
async def logout(
    request: Request,
    response: Response,
    session: SessionDep,
) -> dict[str, bool]:
    now = datetime.now(timezone.utc)
    access_token = bearer_or_cookie(request)
    claims = decode_access_claims(access_token) if access_token else None
    refresh_token = request.cookies.get("aura_refresh")

    conditions = []
    if claims:
        conditions.append(AuthSession.jti == claims["jti"])
    if refresh_token:
        conditions.append(AuthSession.refresh_token_hash == hash_refresh_token(refresh_token))
    if conditions:
        await session.execute(
            update(AuthSession)
            .where(or_(*conditions), AuthSession.revoked_at.is_(None))
            .values(revoked_at=now)
        )
        await session.commit()
    clear_session_cookies(response)
    return {"ok": True}


@router.post("/logout-all")
async def logout_all(
    user: CurrentUser,
    response: Response,
    session: SessionDep,
) -> dict[str, bool]:
    await session.execute(
        update(AuthSession)
        .where(AuthSession.user_id == user.id, AuthSession.revoked_at.is_(None))
        .values(revoked_at=datetime.now(timezone.utc))
    )
    await session.commit()
    clear_session_cookies(response)
    return {"ok": True}



@router.get("/sessions")
async def list_sessions(
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    await enforce_rate_limit(session, f"session-list:{user.id}", limit=30)
    rows = await session.scalars(
        select(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.revoked_at.is_(None),
            AuthSession.refresh_expires_at > datetime.now(timezone.utc),
        )
        .order_by(AuthSession.last_used_at.desc())
    )
    current_id = getattr(request.state, "auth_session_id", None)
    return {
        "sessions": [
            {
                "id": item.id,
                "current": item.id == current_id,
                "ip_address": item.ip_address,
                "user_agent": item.user_agent,
                "created_at": item.created_at.isoformat() if item.created_at else None,
                "last_used_at": item.last_used_at.isoformat() if item.last_used_at else None,
                "expires_at": item.refresh_expires_at.isoformat() if item.refresh_expires_at else None,
            }
            for item in rows
        ]
    }


@router.delete("/sessions/{session_id}")
async def revoke_session(
    session_id: str,
    request: Request,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, bool]:
    await enforce_rate_limit(session, f"session-revoke:{user.id}", limit=30)
    target = await session.scalar(
        select(AuthSession).where(
            AuthSession.id == session_id,
            AuthSession.user_id == user.id,
            AuthSession.revoked_at.is_(None),
        )
    )
    if not target:
        raise HTTPException(status_code=404, detail="Session not found.")
    target.revoked_at = datetime.now(timezone.utc)
    await session.commit()
    if target.id == getattr(request.state, "auth_session_id", None):
        clear_session_cookies(response)
    return {"ok": True}



@router.post("/password/change")
async def change_password(
    payload: PasswordChangeRequest,
    request: Request,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, bool]:
    await enforce_rate_limit(
        session,
        f"password-change:{user.id}",
        limit=5,
        window_seconds=3600,
    )
    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(
            status_code=400,
            detail={"code": "current_password_incorrect", "message": "Current password is incorrect."},
        )

    user.password_hash = hash_password(payload.new_password)
    now = datetime.now(timezone.utc)
    current_session_id = getattr(request.state, "auth_session_id", None)
    await session.execute(
        update(AuthSession)
        .where(
            AuthSession.user_id == user.id,
            AuthSession.id != current_session_id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=now)
    )

    current_session = await session.scalar(
        select(AuthSession).where(
            AuthSession.id == current_session_id,
            AuthSession.user_id == user.id,
            AuthSession.revoked_at.is_(None),
        )
    )
    if not current_session:
        await session.rollback()
        raise HTTPException(status_code=401, detail="Your session expired. Please sign in again.")

    next_jti = str(uuid4())
    next_refresh = new_refresh_token()
    access_token = create_access_token(user.id, jti=next_jti)
    current_session.jti = next_jti
    current_session.refresh_token_hash = hash_refresh_token(next_refresh)
    current_session.access_expires_at = now + timedelta(minutes=settings.access_token_minutes)
    current_session.refresh_expires_at = now + timedelta(days=SESSION_REFRESH_DAYS)
    current_session.last_used_at = now
    await session.commit()
    set_session_cookies(response, access_token, next_refresh)
    set_mobile_session_headers(response, request, access_token, next_refresh)
    return {"ok": True, "other_sessions_revoked": True}


@router.delete("/account")
async def delete_account(
    payload: AccountDeleteRequest,
    user: CurrentUser,
    response: Response,
    session: SessionDep,
) -> dict[str, bool]:
    await enforce_rate_limit(
        session,
        f"account-delete:{user.id}",
        limit=3,
        window_seconds=3600,
    )
    if not verify_password(payload.password, user.password_hash):
        raise HTTPException(
            status_code=400,
            detail={"code": "password_incorrect", "message": "Password is incorrect."},
        )

    # Delete private content explicitly as well as relying on database FK cascades.
    await session.execute(delete(AudioAsset).where(AudioAsset.owner_id == user.id))
    await session.execute(delete(Project).where(Project.owner_id == user.id))
    await session.execute(delete(VoiceFavorite).where(VoiceFavorite.owner_id == user.id))
    await session.execute(delete(UsageBucket).where(UsageBucket.owner_id == user.id))
    await session.execute(delete(FeatureUsageBucket).where(FeatureUsageBucket.owner_id == user.id))
    await session.execute(delete(AuthSession).where(AuthSession.user_id == user.id))
    await session.delete(user)
    await session.commit()
    clear_session_cookies(response)
    return {"ok": True}
