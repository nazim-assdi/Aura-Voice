from __future__ import annotations

import asyncio
import json

import httpx

from app.engines.elevenlabs_tts import ElevenLabsSpeechProvider


def test_elevenlabs_lists_account_voices_for_requested_language() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(
            200,
            json={
                "voices": [
                    {
                        "voice_id": "voice-bn-01",
                        "name": "Bangla Natural",
                        "labels": {"gender": "female"},
                        "verified_languages": [{"language": "bn", "locale": "bn-BD"}],
                    }
                ],
                "has_more": False,
            },
        )

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
            provider = ElevenLabsSpeechProvider(api_key="test-secret")
            return await provider.list_voices("bn-BD")
        finally:
            httpx.AsyncClient = original  # type: ignore[assignment]

    voices = asyncio.run(run())
    assert len(voices) == 1
    assert voices[0].id == "voice-bn-01"
    assert voices[0].locale == "bn-BD"
    assert voices[0].gender == "Female"
    assert seen[0].headers["xi-api-key"] == "test-secret"
    assert seen[0].url.params.get("language") == "bn"


def test_elevenlabs_generates_v4_dialogue_with_selected_delivery_tag() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path.endswith("/v2/voices"):
            return httpx.Response(
                200,
                json={
                    "voices": [
                        {
                            "voice_id": "voice-bn-01",
                            "name": "Bangla Natural",
                            "labels": {"gender": "female"},
                            "verified_languages": [{"language": "bn", "locale": "bn-BD"}],
                        }
                    ]
                },
            )
        return httpx.Response(200, content=b"ID3-test-mp3", headers={"content-type": "audio/mpeg"})

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
            provider = ElevenLabsSpeechProvider(api_key="test-secret", model_id="eleven_v4")
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
    assert generation.headers["xi-api-key"] == "test-secret"
    payload = json.loads(generation.content.decode("utf-8"))
    assert payload["model_id"] == "eleven_v4"
    assert payload["language_code"] == "bn"
    assert payload["inputs"][0]["voice_id"] == "voice-bn-01"
    assert payload["inputs"][0]["text"].startswith("[warm, friendly]")


def test_elevenlabs_rejects_dialogue_over_2000_characters() -> None:
    provider = ElevenLabsSpeechProvider(api_key="test-secret")

    async def run() -> None:
        await provider.synthesize(
            text="ক" * 2001,
            language="bn-BD",
            voice="voice-bn-01",
        )

    try:
        asyncio.run(run())
    except ValueError as error:
        assert "2,000 characters" in str(error)
    else:
        raise AssertionError("Long dialogue should be rejected.")
