from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_endpoint_reports_scaffold_state() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["service"] == "aura-voice-api"
    assert body["speech_ready"] is False


def test_capabilities_do_not_claim_unimplemented_features() -> None:
    response = client.get("/api/v1/capabilities")
    assert response.status_code == 200
    body = response.json()
    assert body["engine_mode"] == "hybrid"
    assert body["speech_generation_ready"] is False
    assert body["voice_cloning_ready"] is False
    assert body["live_audio_routing_ready"] is False


def test_speech_endpoint_fails_clearly_without_provider() -> None:
    response = client.post(
        "/api/v1/speech/generate",
        json={"text": "Hello from Aura", "language": "en"},
    )
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "speech_engine_not_configured"
