# Aura Voice API

The backend exposes health/capabilities endpoints and online neural speech generation.

## Run locally

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# macOS/Linux: source .venv/bin/activate
python -m pip install -r requirements-dev.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Check `/health`, `/api/v1/capabilities`, and `/docs`.

## Speech endpoints

- `GET /api/v1/speech/voices?locale=bn-BD` returns online voices for a locale.
- `POST /api/v1/speech/generate` returns MP3 bytes. JSON body includes `text`, `language`, `voice`, `rate`, and `pitch`.

The default provider is `edge`. It uses the community `edge-tts` Python client and the Edge online neural speech service. It is not an offline engine, is not a Microsoft-supported public API, and may change or become unavailable upstream.

For more expressive, lifelike speech, configure the optional ElevenLabs v4 provider. Set `AURA_SPEECH_PROVIDER=elevenlabs`, `AURA_ELEVENLABS_API_KEY`, and optionally `AURA_ELEVENLABS_MODEL=eleven_v4`. The provider loads voices from the authenticated account and uses the Text to Dialogue endpoint with one speaker and selectable delivery cues. Keep individual requests at or below 2,000 characters. Generation consumes the account's credits; check the provider's current plan and usage limits before production use. Never commit the API key.

The Windows desktop app stores the key with Flutter Secure Storage and injects it into the bundled local backend process only. The backend URL is not shown in the AI Voice Studio workspace. For remote deployments, configure the provider key on the server; do not send user secrets to an untrusted backend.

The API accepts at most 5,000 characters per script and currently limits each client IP to eight generation requests per minute. Keep the API private or behind suitable authentication/rate limiting when deploying it to the public internet. Set `AURA_SPEECH_PROVIDER=none` to disable cloud TTS.

## Client connection

The Flutter client resolves its backend internally. The Windows desktop build starts its bundled server at loopback automatically. Android emulator builds use the host-loopback bridge; physical phones and web clients need a reachable server configured for that deployment. For web clients, set `AURA_CORS_ORIGINS` to the exact deployed web origin.


## Windows one-click start

From the repository root, double-click `Start-Aura-AI.bat`. It creates a local virtual environment, installs `backend/requirements.txt`, then starts Uvicorn on `127.0.0.1:8000`. Keep the terminal open while generating speech from the Windows app. The local endpoint is `http://127.0.0.1:8000`.
