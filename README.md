# Aura Voice Studio

**Professional voice production · Recording · WAV preview · Multitrack audio · AI speech · Dubbing · Restoration · Mixing & mastering**

> Status: early development foundation (v0.1.0). The source includes single-take recording, a non-destructive multitrack editor, callback-driven realtime mixing, live graph replacement and per-track high-pass/compressor controls. Advanced DSP, production TTS, voice cloning, dubbing and mastering remain in development.

Aura Voice Studio focuses exclusively on professional voice and audio production: recording, editing, generating, restoring, dubbing, mixing and mastering speech and audio. The full production workspace is desktop-first (Windows, macOS and Linux), with Android and iOS support for recording, AI voice workflows, review and lightweight editing.

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
├── native/audio_engine/         # Rust PCM renderer and CPAL device I/O
├── docs/                        # product and engineering plans
├── .github/workflows/           # checks and platform build pipelines
└── docker-compose.yml
```

## What works in the current foundation

- Flutter shell with a premium dark theme and responsive navigation.
- FastAPI health and capabilities endpoints plus real online neural speech generation, locale-based voice discovery and MP3 response.
- Speech-provider interface and a safe unavailable provider that fails instead of returning fake audio.
- Initial Rust offline PCM WAV renderer in `native/audio_engine`: integer/float WAV decode, sample-frame clip placement, multitrack gain/pan/mute/solo, fades, sample-peak/clipping report and PCM WAV export.
- Versioned C ABI and public header for offline export, microphone capture, standalone WAV audition and callback-driven real-time multitrack session playback with sample-frame seek, pause/resume and loop controls.
- Flutter FFI adapter with ABI-version check, worker-isolate WAV decoding/session preparation, native-library discovery, microphone capture, standalone WAV preview and real-time multitrack playback sessions, plus explicit web/unsupported-platform fallbacks.
- Studio single-take Record Booth: selectable microphone, live Peak/RMS meters, local 24-bit PCM WAV save, dropped-frame warning and Play/Stop audition with progress.
- Native output-device enumeration/selection for both realtime multitrack playback and standalone WAV preview, worker-side windowed-sinc sample-rate conversion, direct microphone-to-output monitoring with a bounded SPSC bridge/clock servo, and software callback/ring diagnostics.
- Monitor buffer requests, observed input/output callback block sizes, CPAL capture/playback timestamp components and a host-timestamp capture-to-predicted-playback estimate. This is more informative than the ring target alone, but it is not a physical loopback calibration or a driver-underrun counter.
- Local Audio Library: scans RIFF metadata without loading audio payloads, search/sort, saved-take playback, sample-derived waveform preview, rename and confirmed delete. Recordings referenced by saved sessions are protected from rename/delete.
- Local session projects: sample-frame JSON manifests in Documents/Aura Voice Studio/Projects, atomic save with backup recovery, source WAV reference checks, and separate per-project crash-recovery snapshots. The Dashboard lists recoverable autosaves, restores them into regular projects, and confirms before discarding them.
- Early non-destructive multitrack editor: sample-frame ruler and source-range-aware waveforms, long-press move/trim handles, sample-frame split, overlapping crossfades, adjustable 10 ms–1 s snap grid, timeline zoom (25%–400%), 100-step undo/redo, debounced autosave, clip gain/fades/mute, track mute/solo, project save/reopen and a native callback-driven real-time mixer with playhead, sample-frame seek, pause/resume, whole-mix loop and selected-clip loop.
- Rust unit tests for sample-accurate placement, mixing, panning, fades, clipping, format conversion and invalid media. Native CI is configured; check the latest workflow run for its result.
- Backend tests, Docker development setup and CI workflows for the configured platform targets.

## Implemented audio infrastructure and remaining validation

- The realtime mixer uses a sample-time event scheduler and preallocated blocks up to 1024 frames. It visits active clips rather than scanning every project clip for each frame, supports atomic immutable-graph replacement at the next audio block, and converts project PCM to a selected output device's negotiated rate during worker-side graph preparation. Standalone WAV previews now use the same output-device selector and worker-side windowed-sinc resampling. The first DSP lane includes per-track high-pass filtering and an envelope compressor. Studio monitoring requests a small CPAL callback buffer where the host supports it, reports the actual/observed callback block size, ring capacity and host-timestamp capture-to-predicted-playback estimate. Physical Windows/macOS/Linux device benchmarks for dense-session CPU, callback deadlines, driver underruns and loopback-calibrated latency remain outstanding; see [the hardware benchmark runbook](docs/HARDWARE_AUDIO_BENCHMARK.md).
- Advanced DSP beyond the current high-pass/compressor lane, configurable effects graphs, noise restoration, bus/send routing, mastering and loudness/true-peak tools.
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

The AI Voice workspace connects to the FastAPI backend. By default, the backend uses the online Edge neural speech adapter (no API key is requested). It requires internet access and is not an offline model or a Microsoft-supported public API. Voice availability depends on the upstream service. The API caps scripts at 5,000 characters and limits each client to eight speech generations per minute. Keep a publicly deployed backend behind appropriate access controls and rate limiting.

For web builds, set `AURA_CORS_ORIGINS` to the exact website origin. On a physical Android phone, enter a reachable server/LAN URL in AI Voice Studio. An Android emulator uses `http://10.0.2.2:8000`.

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

Native unit tests cover offline/realtime DSP parity, event-based block rendering, seek and clip-boundary scheduling, live graph snapshot lifetime, mute/solo, source-range validation and an 8,192-clip scheduling stress case. Physical audio-device timing and underrun measurements are still required before the mixer can be considered performance-verified.

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
- [x] Voice-studio dashboard, versioned sample-frame session model and serialization tests.
- [x] Initial offline PCM WAV renderer with multitrack mixing, gain/pan, mute/solo, fades and WAV export (native CI passes on the current Rust engine).
- [ ] Verify the new desktop native-library packaging and Flutter-to-Rust render call through CI.
- [x] Flutter media-file access, waveform editor, multitrack project workflow and non-destructive DAW editing controls (source implemented; end-to-end CI verification pending).
- [x] Native microphone device discovery/capture, real-time-safe ring, Flutter input meters and streamed local 24-bit PCM WAV recording (end-to-end CI verification pending).
- [x] Record Booth UI, capture-to-WAV writing, continuous ring draining, playback and selectable output-device/direct microphone monitoring (hardware latency verification pending).
- [x] Callback-driven native realtime multitrack mixer, event-based block scheduler, live graph updates and per-track high-pass/compressor (physical-device and dense-session performance validation pending).
- [x] Separate crash-recovery autosave snapshots with atomic writes, Dashboard restore/discard controls and tests for snapshot promotion/cleanup.
- [x] Worker-side sample-rate conversion for realtime multitrack playback and standalone WAV preview, output-device selection, and direct microphone monitoring with requested/observed device buffer sizes and CPAL host-timestamp latency estimates.
- [ ] Real-device CPU/callback/round-trip latency benchmark on Windows, macOS and Linux; advanced DSP/effects graph, restoration, buses/sends and mastering.
- [ ] Production multilingual TTS and optional local inference.
- [ ] Secure, consent-based voice profile management.
- [ ] Transcription, dubbing, translation review and subtitle export.
- [ ] Mixing, loudness mastering, stems and desktop live routing.

## Contributing

Keep API contracts versioned, add tests for behavior and document model/license requirements with every engine integration. Work directly on the repository's `main` branch.
