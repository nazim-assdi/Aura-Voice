from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_endpoint_reports_configured_speech_provider() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["service"] == "aura-voice-api"
    assert body["speech_provider"] == "edge"
    assert body["speech_ready"] is True
    assert body["speech_mode"] == "online_neural"


def test_capabilities_report_only_implemented_speech_generation() -> None:
    response = client.get("/api/v1/capabilities")
    assert response.status_code == 200
    body = response.json()
    assert body["product"] == "Aura Voice Studio"
    assert body["engine_mode"] == "hybrid"
    assert body["speech_generation_ready"] is True
    assert body["speech_mode"] == "online_neural"
    assert body["recording_ready"] is False
    assert body["multitrack_editing_ready"] is False
    assert body["audio_processing_ready"] is False
    assert body["dubbing_ready"] is False
    assert body["mastering_ready"] is False
    assert body["voice_cloning_ready"] is False
    assert body["live_audio_routing_ready"] is False


def test_speech_endpoint_fails_clearly_without_provider(monkeypatch) -> None:
    from app.api.v1.endpoints import speech

    class OfflineProvider:
        name = "none"
        is_ready = False

        async def list_voices(self, locale: str):
            return []

        async def synthesize(self, **kwargs):
            raise AssertionError("Unavailable provider must not be called")

    monkeypatch.setattr(speech, "get_speech_provider", lambda: OfflineProvider())
    response = client.post(
        "/api/v1/speech/generate",
        json={
            "text": "Hello from Aura",
            "language": "en-US",
            "voice": "en-US-AvaMultilingualNeural",
        },
    )
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "speech_engine_not_configured"


def test_speech_endpoint_returns_generated_mp3(monkeypatch) -> None:
    from app.api.v1.endpoints import speech
    from app.engines.models import SpeechVoice

    class FakeProvider:
        name = "fake"
        is_ready = True

        async def list_voices(self, locale: str):
            return [
                SpeechVoice(
                    id="bn-BD-NabanitaNeural",
                    name="Nabanita",
                    locale="bn-BD",
                    gender="Female",
                )
            ]

        async def synthesize(self, **kwargs):
            assert kwargs["voice"] == "bn-BD-NabanitaNeural"
            assert kwargs["rate"] == 5
            return b"fake-mp3-audio"

    monkeypatch.setattr(speech, "get_speech_provider", lambda: FakeProvider())
    response = client.post(
        "/api/v1/speech/generate",
        json={
            "text": "হ্যালো, অরা ভয়েস।",
            "language": "bn-BD",
            "voice": "bn-BD-NabanitaNeural",
            "rate": 5,
        },
    )
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert response.content == b"fake-mp3-audio"


def test_voice_endpoint_lists_matching_locale(monkeypatch) -> None:
    from app.api.v1.endpoints import speech
    from app.engines.models import SpeechVoice

    class FakeProvider:
        name = "fake"
        is_ready = True

        async def list_voices(self, locale: str):
            assert locale == "bn-BD"
            return [
                SpeechVoice(
                    id="bn-BD-NabanitaNeural",
                    name="Nabanita",
                    locale="bn-BD",
                    gender="Female",
                )
            ]

        async def synthesize(self, **kwargs):
            return b"audio"

    monkeypatch.setattr(speech, "get_speech_provider", lambda: FakeProvider())
    response = client.get("/api/v1/speech/voices?locale=bn-BD")
    assert response.status_code == 200
    assert response.json()[0]["id"] == "bn-BD-NabanitaNeural"


def test_speech_generation_rejects_invalid_tuning_values() -> None:
    response = client.post(
        "/api/v1/speech/generate",
        json={
            "text": "Hello",
            "language": "en-US",
            "voice": "en-US-AvaMultilingualNeural",
            "rate": 80,
        },
    )
    assert response.status_code == 422
