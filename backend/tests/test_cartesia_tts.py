from __future__ import annotations

import asyncio
import json

import httpx

from app.engines.cartesia_tts import CartesiaSpeechProvider


def _voice_response() -> dict:
    return {
        "data": [
            {
                "id": "voice-bn-01",
                "name": "Bangla Natural",
                "gender": "feminine",
                "language": "bn",
                "accents": [{"accent": "standard-bangladesh", "locale": "bn-BD", "is_native": True}],
            }
        ],
        "has_more": False,
        "next_page": None,
    }


def test_cartesia_lists_account_voices_for_requested_locale() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=_voice_response())

    async def run():
        original = httpx.AsyncClient

        class ClientProxy:
            def __init__(self, *args, **kwargs) -> None:
                self._client = original(transport=httpx.MockTransport(handler))

            async def __aenter__(self):
                await self._client.__aenter__()
                return self._client

            async def __aexit__(self, *args):
                return await self._client.__aexit__(*args)

        httpx.AsyncClient = ClientProxy  # type: ignore[assignment]
        try:
            provider = CartesiaSpeechProvider(api_key="test-secret")
            return await provider.list_voices("bn-BD")
        finally:
            httpx.AsyncClient = original  # type: ignore[assignment]

    voices = asyncio.run(run())
    assert len(voices) == 1
    assert voices[0].id == "voice-bn-01"
    assert voices[0].name == "Bangla Natural"
    assert voices[0].locale == "bn-BD"
    assert voices[0].gender == "Female"
    assert seen[0].headers["authorization"] == "Bearer test-secret"
    assert seen[0].headers["cartesia-version"] == "2026-08-14"
    assert seen[0].url.params.get("language") == "bn-BD"
    assert seen[0].url.params.get("limit") == "100"


def test_cartesia_generates_mp3_with_sonic_36_and_bengali_safe_emotion() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/voices":
            return httpx.Response(200, json=_voice_response())
        return httpx.Response(200, content=b"ID3-cartesia-mp3", headers={"content-type": "audio/mpeg"})

    async def run() -> bytes:
        original = httpx.AsyncClient

        class ClientProxy:
            def __init__(self, *args, **kwargs) -> None:
                self._client = original(transport=httpx.MockTransport(handler))

            async def __aenter__(self):
                await self._client.__aenter__()
                return self._client

            async def __aexit__(self, *args):
                return await self._client.__aexit__(*args)

        httpx.AsyncClient = ClientProxy  # type: ignore[assignment]
        try:
            provider = CartesiaSpeechProvider(api_key="test-secret")
            return await provider.synthesize(
                text="আজকের দিনটি খুব সুন্দর।",
                language="bn-BD",
                voice="voice-bn-01",
                delivery="warm",
            )
        finally:
            httpx.AsyncClient = original  # type: ignore[assignment]

    audio = asyncio.run(run())
    assert audio.startswith(b"ID3")
    generation = requests[-1]
    body = json.loads(generation.content.decode("utf-8"))
    assert body["model_id"] == "sonic-3.6"
    assert body["voice"] == "voice-bn-01"
    assert body["language"] == "bn-BD"
    assert body["normalization"] == "auto"
    assert body["output_format"] == {
        "container": "mp3",
        "sample_rate": 44100,
        "bit_rate": 128000,
    }
    assert "encoding" not in body["output_format"]
    assert "emotion" not in body["generation_config"]


def test_cartesia_applies_supported_english_emotion_controls() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/voices":
            return httpx.Response(
                200,
                json={
                    "data": [
                        {
                            "id": "voice-en-01",
                            "name": "Warm English",
                            "gender": "gender_neutral",
                            "language": "en",
                            "accents": [{"locale": "en-US"}],
                        }
                    ]
                },
            )
        return httpx.Response(200, content=b"mp3")

    async def run() -> None:
        original = httpx.AsyncClient

        class ClientProxy:
            def __init__(self, *args, **kwargs) -> None:
                self._client = original(transport=httpx.MockTransport(handler))

            async def __aenter__(self):
                await self._client.__aenter__()
                return self._client

            async def __aexit__(self, *args):
                return await self._client.__aexit__(*args)

        httpx.AsyncClient = ClientProxy  # type: ignore[assignment]
        try:
            provider = CartesiaSpeechProvider(api_key="test-secret")
            await provider.synthesize(
                text="I'm glad we could meet today.",
                language="en-US",
                voice="voice-en-01",
                delivery="warm",
            )
        finally:
            httpx.AsyncClient = original  # type: ignore[assignment]

    asyncio.run(run())
    body = json.loads(requests[-1].content.decode("utf-8"))
    assert body["generation_config"]["emotion"] == "content"


def test_cartesia_reports_invalid_api_key_without_leaking_key() -> None:
    provider = CartesiaSpeechProvider(api_key="private-test-key")
    response = httpx.Response(401, json={"error": "unauthorized"})
    try:
        provider._raise_for_status(response)
    except RuntimeError as error:
        assert "Cartesia rejected" in str(error)
        assert "private-test-key" not in str(error)
    else:
        raise AssertionError("Cartesia should reject an invalid key.")
