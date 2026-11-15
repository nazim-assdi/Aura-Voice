# Aura Voice AI

**Aura Voice Studio · Secure multilingual voice-production workspace**

> **Status: v0.3.0 — development / infrastructure-gated.** The repository now contains an authenticated account/session layer, private project and audio-asset APIs, Cartesia Sonic TTS, Cartesia file STT, an AI translation/dubbing pipeline, browser audio editing, and a Cartesia WebSocket conversation client. Production account storage is not enabled yet because the Render Postgres resource could not be provisioned without payment information. TTS, transcription and realtime provider calls also require valid Cartesia credentials; translation and AI replies require an OpenAI-compatible LLM key/model.

Aura Voice AI is designed for Web, Android, iOS, Windows, macOS and Linux. The Flutter client and browser studio use a versioned FastAPI backend so speech engines and account services remain separate from the UI.

## Repository layout

```text
.
├── app/                         # Flutter client
├── backend/                     # FastAPI API and provider adapters
│   ├── app/api/v1/endpoints/     # auth, projects, assets, speech, dubbing, realtime
│   ├── app/core/                # config, security and quotas
│   ├── app/engines/             # speech provider adapters
│   └── tests/                   # backend tests
├── webapp/                      # responsive browser Voice Studio
├── .github/workflows/           # backend CI and platform builds
├── render.yaml                  # Render API + Postgres Blueprint
└── SECURITY.md
```

## Implemented features

### Accounts and private workspace
- Argon2 password hashing; signed access tokens and revocable server-side sessions.
- HttpOnly/Secure production cookies, refresh-token rotation, mobile token headers, per-IP and per-email login throttles.
- Password change, session listing/revocation, sign-out-all and password-confirmed account deletion.
- Owner-scoped project CRUD and audio asset upload/download/delete.
- Free-tier guardrails in the API: 50 TTS generations or 50,000 TTS characters/day; 20 file transcriptions/day; 30 translations/day; 60 AI conversation turns/day; 50 active projects; 10 MB per audio asset and 100 MB total audio storage per account.
- Voice favourites are stored per account.

**Important:** the production Postgres database is a required dependency for accounts, quotas, projects and audio assets. Without it, `/health` can return HTTP 200 while `database_ready` and `auth_ready` remain false; protected endpoints deliberately reject requests. The current data models store audio bytes in Postgres. The 100 MB per-user cap is a safeguard, not a replacement for object storage at scale.

### Speech and creative tools
- Cartesia Sonic request/response TTS with WAV or MP3 output, voice selection, speed, volume and supported emotion controls.
- Cartesia voice catalogue endpoint and account-owned voice favourites.
- Cartesia file transcription endpoint for supported audio uploads.
- AI dubbing workflow: transcribe → translate → choose target voice → render the new audio track.
- Browser audio editor with waveform preview, trim, gain, fade-in/fade-out and WAV export (processed locally in the browser).
- Cartesia short-lived TTS/STT access tokens and browser WebSocket live conversation flow, with a separate LLM response endpoint.
- Private project storage for scripts and rendered audio, when Postgres is configured.

The editor is a browser-based single-file processing tool, not a multi-track DAW. Real-time STT language availability is model-specific; the current UI exposes English, Spanish, French, Hindi and Japanese for Cartesia Ink-2. File transcription uses the Cartesia Ink-Whisper adapter.

### Clients
- Responsive browser studio: https://aura-voice-studio.onrender.com
- Flutter app for Android, iOS, Windows, macOS, Linux and Web.
- The browser audio editor currently works client-side; uploaded/generated outputs are persisted only when the account database is available.

## Required server configuration

Set secrets in the Render service Environment page. Never commit secret values or put provider keys in Flutter, JavaScript, browser storage or build-time public variables.

| Variable | Required for | Notes |
|---|---|---|
| `AURA_ENVIRONMENT` | production | Set to `production` |
| `AURA_DATABASE_URL` | accounts/projects/quotas | Render Postgres async connection string |
| `AURA_AUTH_JWT_SECRET` | accounts/sessions | At least 32 random characters; use Render-generated secret |
| `AURA_SPEECH_PROVIDER` | TTS/STT | `cartesia` |
| `AURA_CARTESIA_API_KEY` | TTS/STT/realtime | Keep server-side only |
| `AURA_LLM_API_KEY` | translation/AI replies | OpenAI-compatible provider key |
| `AURA_LLM_MODEL` | translation/AI replies | A model enabled for the supplied provider |
| `AURA_CORS_ORIGINS` | browser client | Comma-separated trusted origins |

Optional Cartesia settings: `AURA_CARTESIA_MODEL_ID=sonic-3.6`, `AURA_CARTESIA_STT_MODEL_ID=ink-whisper`, `AURA_CARTESIA_REALTIME_STT_MODEL_ID=ink-2`, `AURA_CARTESIA_VERSION=2026-08-14`, `AURA_CARTESIA_TIMEOUT_SECONDS=45`, and `AURA_CARTESIA_VOICE_ID` (a default voice is not required when the caller selects one).

The repository's `render.yaml` defines a Singapore Postgres resource and wires its connection string into the API service. Its current Render Blueprint preview was blocked by the account's missing payment information; no Postgres instance was created. The Blueprint auto-sync has been disabled to prevent an unreviewed paid resource from being provisioned. Review the plan and cost in Render before approving it.

## Local development

Requires Python 3.11+ and Flutter stable.

```bash
# Backend
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# macOS/Linux: source .venv/bin/activate
python -m pip install -r requirements-dev.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

For local development only, the backend can use SQLite by leaving `AURA_DATABASE_URL` blank while `AURA_ENVIRONMENT` is not production. Use a separate local JWT secret of at least 32 characters. Production mode intentionally does not fall back to SQLite.

```bash
# Flutter client
cd app
flutter pub get
flutter run --dart-define=AURA_API_BASE_URL=http://127.0.0.1:8000
```

For Android emulator networking, use `http://10.0.2.2:8000`. A physical device needs the computer's reachable LAN address and a matching local CORS origin.

## API overview

- `GET /health` — liveness and actual provider/database readiness.
- `POST /api/v1/auth/register`, `/login`, `/refresh`, `/logout`, `/logout-all`.
- `GET /api/v1/auth/me`, `/usage`, `/sessions`; `DELETE /api/v1/auth/sessions/{id}`.
- `POST /api/v1/auth/password/change`; `DELETE /api/v1/auth/account`.
- `/api/v1/projects` — owner-scoped project CRUD.
- `/api/v1/projects/{project_id}/assets` — private audio asset upload/download/delete.
- `GET /api/v1/speech/voices`; `POST /api/v1/speech/generate`.
- `/api/v1/dubbing/transcribe`, `/translate`, `/render`.
- `/api/v1/realtime/token`, `/respond`.

OpenAPI docs are served at `/docs` when the API is running.

## Security and remaining work

Implemented account/session controls and request limits are an initial security baseline, not a guarantee of abuse-proof production operation. Before opening public registration, finish database provisioning, add email verification and password reset, configure a backup/retention policy, move audio bytes to private object storage, add monitoring/abuse review and test quotas under concurrency. Realtime usage also needs provider-side spend monitoring. See [SECURITY.md](SECURITY.md).

Not implemented: voice cloning/enrollment, verified consent records for voice profiles, team workspaces and billing, email verification/password reset, object storage lifecycle, multi-track editing, subtitle export, cryptographic watermarking, offline model packs and signed store releases.

## Build artifacts

The GitHub Actions workflow targets:
- Android: APK and AAB.
- iOS: unsigned app bundle; Apple signing is still required.
- Windows: app folder packaged as ZIP.
- macOS: app bundle packaged as ZIP.
- Linux: release bundle packaged as TAR.GZ.
- Web: Flutter web build packaged as ZIP.

A platform listed here is a build target, not a claim that the latest run passed. Check [GitHub Actions](https://github.com/nazim-assdi/Aura-Voice/actions) for the current result.
