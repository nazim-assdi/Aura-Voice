from app.core.security import (
    create_access_token,
    decode_access_claims,
    hash_password,
    hash_refresh_token,
    new_refresh_token,
    verify_password,
)
from app.core.config import settings


def test_passwords_are_hashed_and_verified() -> None:
    raw = "A-Long-Password-With-Unique-Characters"
    stored = hash_password(raw)
    assert stored != raw
    assert verify_password(raw, stored)
    assert not verify_password("incorrect-password", stored)


def test_refresh_tokens_are_opaque_and_hashed() -> None:
    first = new_refresh_token()
    second = new_refresh_token()
    assert first != second
    assert len(first) >= 40
    assert hash_refresh_token(first) != first
    assert hash_refresh_token(first) != hash_refresh_token(second)


def test_access_token_contains_bound_issuer_audience_and_session_id(monkeypatch) -> None:
    monkeypatch.setattr(settings, "auth_jwt_secret", "unit-test-secret-that-is-long-enough-for-hs256")
    monkeypatch.setattr(settings, "environment", "test")
    monkeypatch.setattr(settings, "database_url", "sqlite+aiosqlite:///./aura-test.db")

    token = create_access_token("user-123", jti="session-456")
    claims = decode_access_claims(token)

    assert claims == {"sub": "user-123", "jti": "session-456"}
    assert decode_access_claims(token + "tampered") is None


def test_access_token_is_disabled_without_a_secret(monkeypatch) -> None:
    monkeypatch.setattr(settings, "auth_jwt_secret", "")
    assert decode_access_claims("not-a-token") is None
