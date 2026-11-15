import asyncio

import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app import db
from app.main import app


@pytest.fixture
def authenticated_client(tmp_path, monkeypatch):
    old_values = {
        "database_url": settings.database_url,
        "environment": settings.environment,
        "auth_jwt_secret": settings.auth_jwt_secret,
        "secure_cookies": settings.secure_cookies,
        "speech_provider": settings.speech_provider,
        "cartesia_api_key": settings.cartesia_api_key,
    }

    settings.database_url = f"sqlite+aiosqlite:///{tmp_path / 'aura-test.db'}"
    settings.environment = "test"
    settings.auth_jwt_secret = "aura-test-only-secret-that-is-at-least-32-bytes"
    settings.secure_cookies = False
    settings.speech_provider = "none"
    settings.cartesia_api_key = ""

    db._engine = None
    db._session_factory = None
    app.state.database_ready = False

    try:
        with TestClient(app) as client:
            yield client
    finally:
        engine = db._engine
        if engine is not None:
            asyncio.run(engine.dispose())
        db._engine = None
        db._session_factory = None
        for key, value in old_values.items():
            setattr(settings, key, value)
        app.state.database_ready = False
