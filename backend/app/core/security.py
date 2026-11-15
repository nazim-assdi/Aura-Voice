import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import jwt
from fastapi import HTTPException, Request, status
from pwdlib import PasswordHash

from app.core.config import settings

password_hasher = PasswordHash.recommended()


def hash_password(password: str) -> str:
    return password_hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return password_hasher.verify(password, password_hash)
    except Exception:
        return False


def new_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_access_token(subject: str, *, jti: str | None = None) -> str:
    if not settings.auth_ready:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "auth_not_configured",
                "message": "A persistent database and a 32-character JWT secret are required.",
            },
        )
    now = datetime.now(timezone.utc)
    payload = {
        "sub": subject,
        "jti": jti or str(uuid4()),
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_minutes),
        "iss": "aura-voice-api",
        "aud": "aura-voice-client",
    }
    return jwt.encode(payload, settings.auth_jwt_secret, algorithm="HS256")


def decode_access_claims(token: str) -> dict[str, str] | None:
    if not settings.auth_jwt_secret.strip():
        return None
    try:
        payload = jwt.decode(
            token,
            settings.auth_jwt_secret,
            algorithms=["HS256"],
            issuer="aura-voice-api",
            audience="aura-voice-client",
            options={"require": ["sub", "exp", "iat", "jti"]},
        )
        subject = payload.get("sub")
        jti = payload.get("jti")
        if not isinstance(subject, str) or not isinstance(jti, str):
            return None
        return {"sub": subject, "jti": jti}
    except jwt.InvalidTokenError:
        return None


def decode_access_token(token: str) -> str | None:
    claims = decode_access_claims(token)
    return claims["sub"] if claims else None


def bearer_or_cookie(request: Request) -> str | None:
    authorization = request.headers.get("authorization", "")
    if authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return request.cookies.get("aura_session")


def auth_not_ready() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail={
            "code": "auth_not_configured",
            "message": "Authentication is locked until AURA_DATABASE_URL and AURA_AUTH_JWT_SECRET are configured on the backend.",
        },
    )
