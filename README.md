# Aura Voice AI

**Premium omni-voice and emotion studio · Hybrid cloud + optional on-device engines**

> Status: early development scaffold (v0.1.0). This repository establishes the product architecture and a runnable UI/API foundation. Voice cloning, production TTS, real-time call routing, watermark embedding, and app-store-ready signing are not implemented yet.

Aura Voice AI is designed as a cross-platform voice workspace for Android, iOS, Windows, macOS, Linux, and Web. The hybrid architecture keeps the interface independent from speech engines so local and hosted providers can be added without rewriting the app.

## Repository layout

```
.
├── app/                         # Flutter client
│   └── lib/
│       ├── core/                # theme, API client and configuration
│       └── features/             # dashboard and studio navigation
├── backend/                     # FastAPI service
│   ├── app/
│   │   ├── api/v1/              # versioned HTTP endpoints
│   │   ├── core/                # settings
│   │   └── engines/             # provider contract and registry
│   └── tests/
├── .github/workflows/           # checks and platform build pipelines
├── docker-compose.yml
└── SECURITY.md
```

## What works in this foundation

- Flutter app shell with premium dark visual system and responsive dashboard/navigation.
- API connectivity indicator and a FastAPI health endpoint.
- Versioned capabilities endpoint describing which engines are actually available.
- Provider interface and a safe `none` provider that reports speech generation as unavailable instead of returning fake audio.
- Backend tests, Docker development setup, and CI build jobs for Android, iOS (unsigned), Windows, macOS, Linux, and Web.

## What is not implemented yet

- Speech synthesis or voice cloning model inference.
- Voice sample recording/upload, identity verification, and durable consent records.
- Emotion/accent controls connected to a model.
- Real-time microphone/call routing or virtual audio devices.
- Audio editing, dubbing, subtitle export, and cryptographic watermark embedding.
- Signed installers, Apple provisioning, and store submissions.

These capabilities are intentionally not represented as completed features. The next milestones are listed below.

## Run the Flutter client

Install the Flutter stable SDK for your operating system, then:

```bash
cd app
flutter create --platforms=android,ios,web,windows,macos,linux .
flutter pub get
flutter run
```

To point the client at a backend, pass the API base URL at build/run time:

```bash
flutter run --dart-define=AURA_API_BASE_URL=http://127.0.0.1:8000
```

For the Android emulator, use `http://10.0.2.2:8000` instead of `127.0.0.1`. A physical phone needs the computer's reachable LAN address and matching backend/CORS configuration.

## Run the FastAPI backend

Requires Python 3.11 or newer.

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\Scripts\Activate.ps1
# macOS/Linux: source .venv/bin/activate
python -m pip install -r requirements-dev.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Check `http://127.0.0.1:8000/health` and API docs at `http://127.0.0.1:8000/docs`.

### Docker

From the repository root:

```bash
docker compose up --build
```

Copy `.env.example` to `.env` before configuring environment-specific values. Never commit real API keys or private audio.

## Build targets

The GitHub Actions workflow creates platform artifacts on pushes and pull requests:

| Target | Output |
|---|---|
| Android | Release APK and AAB |
| iOS | Unsigned iOS app bundle (requires Apple signing for install/distribution) |
| Windows | Release app folder packaged as ZIP |
| macOS | Release app bundle packaged as ZIP |
| Linux | Release bundle packaged as TAR.GZ |
| Web | Static web build packaged as ZIP |

Desktop build outputs are not automatically installers. Store releases and signed installers require platform-specific certificates, packaging, and review.

## Hybrid engine design

The client talks to the versioned API, not directly to a model. The backend exposes an engine contract under `backend/app/engines/`. A provider should only be marked ready after its model is installed, its license is reviewed, and an inference smoke test passes.

Recommended integration order:

1. Add one reliable multilingual TTS provider behind the engine contract.
2. Add optional local inference adapters after measuring device RAM, CPU/GPU use, latency, and supported languages.
3. Add voice-profile enrollment only with explicit, recorded permission from the voice owner and authenticated account ownership.
4. Add emotion/accent conditioning only for models that support it; do not imply sliders change a voice until inference is wired.
5. Add live routing as a separate desktop/OS integration, not as a universal Flutter feature.

Model weights are deliberately not committed. They can be large, licensed, and may contain sensitive assets.

## Responsible voice use

Aura Voice AI must be used only with voices the user owns or is explicitly authorized to use. Before any voice-profile enrollment or cloning feature ships, implement authenticated accounts, a clear permission flow, revocation/deletion, audit records, abuse reporting, rate limits, and provenance disclosure. Do not build impersonation, fraud, or non-consensual cloning workflows. See [SECURITY.md](SECURITY.md).

## Development roadmap

- [x] Monorepo, premium Flutter shell, API health/capabilities, provider contract, tests and build automation.
- [ ] Add authenticated user/session foundation and persistent consent records.
- [ ] Integrate and benchmark the first cloud TTS engine.
- [ ] Add optional offline TTS adapter and downloadable model packs.
- [ ] Implement voice profile management with consent, deletion and access controls.
- [ ] Add audio editor, translation/dubbing pipeline and export formats.
- [ ] Add provenance watermarking and verification.
- [ ] Implement desktop live-audio routing; assess mobile OS constraints separately.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Keep API contracts versioned, add tests for behavior, and document model/license requirements with every new engine.
