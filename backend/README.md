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

The default provider is `edge`. It uses the community `edge-tts` Python client and the Edge online neural speech service. It is not an offline engine, is not a Microsoft-supported public API, and may change or become unavailable upstream. For offline synthesis, replace it with a licensed local provider adapter and benchmark the model before marking it ready.

The API accepts at most 5,000 characters per script and currently limits each client IP to eight generation requests per minute. Keep the API private or behind suitable authentication/rate limiting when deploying it to the public internet. Set `AURA_SPEECH_PROVIDER=none` to disable cloud TTS.

## Client connection

The Flutter client can store a backend base URL in AI Voice Studio. Common addresses:

- Desktop running API locally: `http://127.0.0.1:8000`
- Android emulator: `http://10.0.2.2:8000`
- Physical phone: use the computer/server's reachable LAN or HTTPS address.

For web clients, set `AURA_CORS_ORIGINS` to the exact deployed web origin.
