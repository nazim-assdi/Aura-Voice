from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import SessionDep, CurrentUser
from app.core.config import settings
from app.core.limits import enforce_rate_limit
from app.core.security import (
    auth_not_ready,
    create_access_token,
    hash_password,
    verify_password,
)
from app.models import User, UsageBucket

router = APIRouter(prefix="/auth")


class RegisterRequest(BaseModel):
    email: str = Field(min_length=5, max_length=320)
    display_name: str = Field(min_length=2, max_length=80)
    password: str = Field(min_length=10, max_length=128)


class LoginRequest(BaseModel):
    email: str = Field(min_length=5, max_length=320)
    password: str = Field(min_length=1, max_length=128)


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    email: str
    display_name: str
    plan: str


def normalize_email(value: str) -> str:
    value = value.strip().lower()
    if value.count("@") != 1 or "." not in value.rsplit("@", 1)[-1]:
        raise HTTPException(status_code=422, detail="Enter a valid email address.")
    return value


def set_session_cookie(response: Response, token: str) -> None:
    response.set_cookie(
        key="aura_session",
        value=token,
        max_age=settings.access_token_minutes * 60,
        httponly=True,
        secure=settings.secure_cookies,
        samesite="none" if settings.secure_cookies else "lax",
        path="/",
    )


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
        session, f"register:{request.client.host if request.client else 'unknown'}",
        limit=5, window_seconds=3600,
    )
    email = normalize_email(payload.email)
    existing = await session.scalar(select(User).where(func.lower(User.email) == email))
    if existing:
        raise HTTPException(status_code=409, detail={"code": "email_in_use", "message": "An account with this email already exists."})
    user = User(
        id=str(uuid4()),
        email=email,
        display_name=payload.display_name.strip(),
        password_hash=hash_password(payload.password),
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    token = create_access_token(user.id)
    set_session_cookie(response, token)
    if request.headers.get("x-client-type") == "mobile":
        response.headers["X-Aura-Access-Token"] = token
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
        session, f"login:{request.client.host if request.client else 'unknown'}",
        limit=12, window_seconds=300,
    )
    email = normalize_email(payload.email)
    user = await session.scalar(select(User).where(func.lower(User.email) == email))
    # A fixed-cost dummy hash verification reduces account-enumeration timing leakage.
    if not user or not verify_password(payload.password, user.password_hash) or not user.is_active:
        raise HTTPException(status_code=401, detail={"code": "invalid_credentials", "message": "Email or password is incorrect."})
    token = create_access_token(user.id)
    set_session_cookie(response, token)
    if request.headers.get("x-client-type") == "mobile":
        response.headers["X-Aura-Access-Token"] = token
    return user


@router.get("/me", response_model=UserResponse)
async def me(user: CurrentUser) -> User:
    return user


@router.get("/usage")
async def usage(user: CurrentUser, session: SessionDep) -> dict[str, int | str]:
    from datetime import date

    bucket = await session.scalar(
        select(UsageBucket).where(
            UsageBucket.owner_id == user.id,
            UsageBucket.period_key == date.today().isoformat(),
        )
    )
    return {
        "plan": user.plan,
        "period": date.today().isoformat(),
        "generations_today": bucket.generation_count if bucket else 0,
        "characters_today": bucket.character_count if bucket else 0,
        "daily_generation_limit": 50,
        "daily_character_limit": 50000,
    }


@router.post("/logout")
async def logout(response: Response) -> dict[str, bool]:
    response.delete_cookie(
        "aura_session",
        path="/",
        httponly=True,
        secure=settings.secure_cookies,
        samesite="none" if settings.secure_cookies else "lax",
    )
    return {"ok": True}
