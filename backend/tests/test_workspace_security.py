def register(client, email="creator@example.com", password="strong-password-123"):
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": email,
            "display_name": "Aura Creator",
            "password": password,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_register_login_and_private_project_owner_scope(authenticated_client):
    client = authenticated_client
    user_a = register(client, "a@example.com")
    project = client.post(
        "/api/v1/projects",
        json={
            "name": "Private voice project",
            "script": "This is a private script.",
            "language": "en",
            "settings": {"voice_id": "voice-a", "speed": 1.0},
        },
    )
    assert project.status_code == 201, project.text
    project_id = project.json()["id"]

    assert client.get("/api/v1/auth/me").json()["id"] == user_a["id"]
    user_b = register(client, "b@example.com")
    assert user_b["id"] != user_a["id"]

    # A second account must not discover or read the first account's project.
    assert client.get("/api/v1/projects").json()["projects"] == []
    assert client.get(f"/api/v1/projects/{project_id}").status_code == 404

    client.post("/api/v1/auth/logout")
    assert client.get("/api/v1/auth/me").status_code == 401


def test_password_change_rotates_current_session_and_revokes_other_sessions(authenticated_client):
    client = authenticated_client
    register(client)
    old_token = client.cookies.get("aura_session")
    assert old_token

    changed = client.post(
        "/api/v1/auth/password/change",
        json={
            "current_password": "strong-password-123",
            "new_password": "new-strong-password-456",
        },
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["other_sessions_revoked"] is True
    assert client.cookies.get("aura_session") != old_token
    assert client.get("/api/v1/auth/me").status_code == 200

    client.post("/api/v1/auth/logout")
    assert client.post(
        "/api/v1/auth/login",
        json={"email": "creator@example.com", "password": "strong-password-123"},
    ).status_code == 401
    assert client.post(
        "/api/v1/auth/login",
        json={"email": "creator@example.com", "password": "new-strong-password-456"},
    ).status_code == 200


def test_account_deletion_removes_private_workspace_and_sessions(authenticated_client):
    client = authenticated_client
    user = register(client, "delete@example.com")
    project = client.post(
        "/api/v1/projects",
        json={"name": "Remove me", "script": "private"},
    )
    assert project.status_code == 201, project.text
    project_id = project.json()["id"]

    deleted = client.request(
        "DELETE",
        "/api/v1/auth/account",
        json={"password": "strong-password-123"},
    )
    assert deleted.status_code == 200, deleted.text
    assert deleted.json()["ok"] is True
    assert client.get("/api/v1/auth/me").status_code == 401
    assert client.post(
        "/api/v1/auth/login",
        json={"email": "delete@example.com", "password": "strong-password-123"},
    ).status_code == 401


def test_register_rate_limit_blocks_sixth_signup_from_same_ip(authenticated_client):
    client = authenticated_client
    for index in range(5):
        response = client.post(
            "/api/v1/auth/register",
            json={
                "email": f"rate-{index}@example.com",
                "display_name": "Rate Creator",
                "password": "strong-password-123",
            },
        )
        assert response.status_code == 201, response.text

    blocked = client.post(
        "/api/v1/auth/register",
        json={
            "email": "rate-6@example.com",
            "display_name": "Rate Creator",
            "password": "strong-password-123",
        },
    )
    assert blocked.status_code == 429
    assert blocked.json()["detail"]["code"] == "rate_limit_exceeded"
    assert int(blocked.headers["Retry-After"]) > 0


def test_unauthenticated_project_and_audio_generation_are_rejected(authenticated_client):
    client = authenticated_client
    assert client.get("/api/v1/projects").status_code == 401
    speech = client.post(
        "/api/v1/speech/generate",
        json={"text": "This must not be public.", "language": "en"},
    )
    assert speech.status_code == 401
    assert speech.json()["detail"]["code"] == "authentication_required"
