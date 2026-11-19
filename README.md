# Aura Voice Studio

**Professional voice production · Multitrack audio · AI speech · Dubbing · Restoration · Mixing & mastering**

> Status: early development foundation (v0.1.0). The repository currently contains a Flutter app shell, FastAPI health/capabilities endpoints, a provider contract and tests. Real recording, production TTS, voice cloning, multitrack editing, DSP, dubbing and mastering are still in development.

Aura Voice Studio is a voice-only product. It is **not a video editor**. The goal is a professional voice-production workstation for recording, editing, generating, restoring, dubbing, mixing and mastering speech and audio. The full production workspace is desktop-first (Windows, macOS and Linux), with Android and iOS support for recording, AI voice workflows, review and lightweight editing.

## Product workspaces

- **Record:** microphone selection, input monitoring, meters, take lanes, punch-in/out and recording scripts.
- **Multitrack Editor:** waveforms, clip editing, fades, crossfades, comping, automation, routing and non-destructive sessions.
- **Voice Processing:** EQ, compressor, de-esser, gate, limiter, noise cleanup, reverb, delay and pitch/time tools.
- **AI Voice Studio:** multilingual TTS, script editor, pronunciation dictionary, voice styles and authorized voice profiles.
- **Dubbing & Localization:** transcription, translation review, speaker segments, timing alignment and SRT/VTT export.
- **Mix & Master:** buses, sends, loudness/true-peak meters, reference tracks, stems and export presets.
- **Live Voice (desktop):** low-latency microphone effects and OS-specific virtual audio routing.

A feature is only advertised as ready after its real engine is integrated and tested. UI controls must not pretend to process or generate audio when no provider is available.

## Repository layout

```
.
├── app/                         # Flutter client
│   └── lib/
│       ├── core/                # theme, API client and configuration
│       └── features/            # voice workspace modules
├── backend/                     # FastAPI service
│   ├── app/
│   │   ├── api/v1/              # versioned HTTP endpoints
│   │   ├── core/                # settings
│   │   └── engines/             # speech provider contract and registry
│   └── tests/
├── docs/                        # product and engineering plans
├── .github/workflows/           # checks and platform build pipelines
└── docker-compose.yml
```

## What works in the current foundation

- Flutter shell with a premium dark theme and responsive navigation.
- FastAPI health endpoint and versioned capabilities endpoint.
- Speech-provider interface and a safe unavailable provider that fails instead of returning fake audio.
- Initial Rust offline PCM WAV renderer in `native/audio_engine`: integer/float WAV decode, sample-frame clip placement, multitrack gain/pan/mute/solo, fades, sample-peak/clipping report and PCM WAV export.
- Rust unit tests for sample-accurate placement, mixing, panning, fades, clipping, format conversion and invalid media. Native CI is configured; check the latest workflow run for its result.
- Backend tests, Docker development setup and CI workflows for the configured platform targets.

## What is not implemented yet

- Real microphone capture, monitoring, multi-track editing or audio export.
- Production audio DSP, noise restoration, effects graph or mastering.
- Production TTS inference, voice profile enrollment or voice cloning.
- Speech recognition, translation/dubbing alignment and subtitle export.
- Desktop virtual audio routing, signed installers and app-store releases.

## Run the Flutter client

Install Flutter stable, then:

```bash
cd app
flutter create --platforms=android,ios,web,windows,macos,linux .
flutter pub get
flutter run
```

Configure the API base URL at run time:

```bash
flutter run --dart-define=AURA_API_BASE_URL=http://127.0.0.1:8000
```

For the Android emulator, use `http://10.0.2.2:8000` instead of `127.0.0.1`. A physical phone needs the computer's reachable LAN address and matching backend/CORS configuration.

## Test the native offline audio renderer

Requires the stable Rust toolchain:

```bash
cd native/audio_engine
cargo test --all-targets
```

The renderer intentionally accepts decoded PCM assets at the session sample rate. It does not yet perform resampling, compressed-audio decoding, microphone capture or realtime playback.

## Run the FastAPI backend

Requires Python 3.11 or newer.

```bash
cd backend
python -m venv .venv
# Windows PowerShell: .venv\\Scripts\\Activate.ps1
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

Copy `.env.example` to `.env` before configuring environment-specific values. Never commit API keys, private recordings or voice samples.

## Technical direction

- Flutter for the responsive UI and project workflows.
- A native Rust/C++ audio engine behind a stable FFI for realtime capture, playback, DSP and multitrack mixing.
- FastAPI for optional cloud AI providers, accounts, consent and synchronization. Local recording/editing must not depend on cloud availability.
- Tested audio libraries for decoding, resampling, DSP and encoding; codec and dependency licenses must be reviewed before distribution.
- A versioned non-destructive session format using exact sample-frame positions.
- Offline model packs are optional and must be benchmarked for RAM, CPU/GPU use, latency, language coverage and license.

## Responsible voice use

Aura Voice must only generate or clone voices the user owns or is explicitly authorized to use. Before voice profiles or cloning ship, implement authenticated ownership, explicit recorded consent, revocation, deletion, audit records, abuse reporting, rate limits and provenance disclosure. Do not build impersonation, fraud or non-consensual cloning workflows. See [SECURITY.md](SECURITY.md).

## Roadmap

See [docs/PRO_VOICE_STUDIO_ARCHITECTURE.md](docs/PRO_VOICE_STUDIO_ARCHITECTURE.md) for the detailed feature requirements, engineering design and acceptance gates.

- [x] Flutter/FastAPI foundation, health/capabilities and safe provider contract.
- [ ] Professional voice-studio workspace and project/session model.
- [ ] Real recording, playback, waveform and multitrack editing.
- [ ] Native audio graph, DSP and restoration.
- [ ] Production multilingual TTS and optional local inference.
- [ ] Secure, consent-based voice profile management.
- [ ] Transcription, dubbing, translation review and subtitle export.
- [ ] Mixing, loudness mastering, stems and desktop live routing.

## Contributing

Keep API contracts versioned, add tests for behavior and document model/license requirements with every engine integration. Work directly on the repository's `main` branch.
