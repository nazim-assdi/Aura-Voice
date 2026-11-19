# Aura Voice Studio — Product Architecture & Delivery Plan

## Product direction

**Aura Voice** is a professional voice-production and audio-workstation application. It is not a video editor. The product combines a recording booth, multitrack voice editor, AI speech studio, dubbing workspace, audio restoration tools and a mastering suite.

The full production workspace is desktop-first (Windows, macOS and Linux). Android and iOS provide voice recording, script/TTS workflows, review, light edits and project handoff. A consistent project format keeps sessions portable across supported platforms.

This repository is an early Flutter/FastAPI/native-engine foundation. In addition to the UI and API shell, source now includes single-take microphone capture to a local 24-bit PCM WAV file and saved-WAV audition through the default output. Full session-based multitrack recording/editing, production TTS, voice cloning, DSP, dubbing and mastering are not yet implemented. Roadmap items below are requirements, not claims of completed functionality.

## Product principles

1. Audio must never be fabricated: a capability is marked ready only after a real engine passes its smoke tests.
2. A session has one versioned source of truth used by preview, processing and export.
3. Editing is non-destructive; original recordings remain untouched.
4. Recording and monitoring must be low-latency, with device selection, input meters and clear monitoring state.
5. Offline recording, editing and export should work without an account or cloud connection wherever the OS permits.
6. Cloud AI features are opt-in. Voice profiles require explicit authorization from the voice owner, revocation and deletion.
7. Export must report sample rate, bit depth, channel count, loudness and codec honestly.

## Core product workspaces

### 1. Record
- Select microphone/input device, channel count and sample rate.
- Input monitoring, peak/RMS meters, clipping warning and input gain where supported.
- Arm tracks, record, pause, punch-in/out, count-in, loop recording and take lanes.
- Metronome, markers, script/teleprompter and recording notes.
- Device latency calibration and monitoring safety controls.

### 2. Multitrack Voice Editor
- Unlimited-by-design project tracks, constrained by actual device performance.
- Waveform rendering, zoom, horizontal scroll, snapping, markers and range selection.
- Split, trim, move, duplicate, slip, fade, crossfade, ripple delete and clip gain.
- Comping/take lanes, non-destructive silence removal and room-tone preservation.
- Track mute, solo, record-arm, input/output routing, pan and automation.
- Undo/redo, autosave, crash recovery and portable project relinking.

### 3. Voice Processing & Restoration
- Parametric EQ, high-pass/low-pass filters, compressor, limiter, expander/gate and de-esser.
- Noise reduction, hum removal, click/pop repair and plosive reduction.
- Reverb, delay, saturation, pitch correction and time-stretch where a tested engine is available.
- Presets are starting points; every parameter must affect the actual audio graph and rendered file.
- A/B bypass, gain matching, effect ordering and non-destructive per-track chains.

### 4. AI Voice Studio
- Multilingual text-to-speech with voice, language, rate, pitch and supported style controls.
- Script editor with paragraph-level generation, pronunciation dictionary and reusable projects.
- Voice profiles with explicit, revocable owner consent and secure source-audio handling.
- Similarity/style controls only where the selected model genuinely supports them.
- Generation queue, progress, retry, cancellation, usage limits and provenance disclosure.
- Local model packs as an optional path after RAM/CPU/GPU benchmarking and license review.

### 5. Dubbing & Localization
- Import source audio and subtitle/transcript files.
- Speech-to-text, editable transcript, speaker/scene segments and translation review.
- Generate authorized target-language speech, align timing and adjust pauses/speed.
- Compare source and dub, loudness match, export stems and subtitle formats (SRT/VTT).
- Human review remains available; automatic translation is never represented as verified.

### 6. Mix & Master
- Track groups, sends/returns, buses, sidechain routing and automation.
- Peak, RMS and LUFS meters; true-peak ceiling and clipping checks.
- Reference track, loudness target presets, stereo/mono compatibility and phase checks.
- Export WAV/PCM first; add FLAC, MP3, AAC and other formats only with verified encoders and license review.
- Batch export, stems, metadata, render queue and repeatable mastering presets.

### 7. Live Voice & Broadcast (desktop)
- Low-latency microphone processing chain and virtual-device routing where supported by the OS.
- Push-to-talk, noise gate, compressor, EQ, limiter and monitor mix.
- Device reconnect handling, loopback feedback protection and CPU/latency indicators.
- Platform-specific drivers and permissions are required; this is not a universal Flutter-only feature.

## Technical architecture

### Flutter application
- Premium responsive workspace with a desktop mixer/editor layout and touch-friendly mobile layout.
- Modules: dashboard, record, sessions, multitrack editor, voice generation, dubbing, effects, mixer, library and settings.
- Command-based editing, undo/redo, keyboard shortcuts, autosave and accessible controls.
- UI state reflects actual engine capabilities. Disabled features explain what is missing.

### Native audio engine
- Build a stable Rust or C++ engine behind a typed Flutter FFI boundary.
- Evaluate platform audio I/O APIs (Core Audio, WASAPI, ALSA/PipeWire and mobile audio APIs) for low-latency capture/playback.
- Use an explicit audio graph with typed nodes for input, playback, gain, EQ, dynamics, effects, buses and output.
- Use a common sample-time clock, deterministic buffer scheduling, resampling and channel mapping.
- Separate realtime-safe processing from non-realtime file rendering; never allocate, block on network or do file I/O in the realtime audio callback.
- Add CPU fallback and capability reporting for every accelerated or optional effect.

### File and DSP pipeline
- Probe and decode supported media; create waveform/peak caches and session proxies when useful.
- Use tested libraries for resampling, filtering, FFT/spectral processing and encoding; document codec and dependency licenses.
- Keep sample format, channel layout, sample rate and timebase explicit in the project model.
- Use offline high-quality rendering for export and low-latency buffers for monitoring.
- Verify output with signal-level tests and reference audio fixtures.

### AI provider layer
- Keep the existing FastAPI versioned provider boundary.
- Implement provider adapters for TTS, speech recognition, translation, voice conversion and optional voice profiles.
- Keep model weights outside Git. Check license, security, language coverage, latency and hardware requirements.
- Do not expose credentials in the client. Use server-side secrets for cloud providers.
- Mark an engine ready only after configuration, license review and successful inference smoke tests.

### Project format
- Versioned JSON session manifest with assets, sample rate, bit depth, channel layouts, tracks, clips, takes, markers, routing, automation, effect chains and export settings.
- Store positions and lengths as integer sample frames (or exact rational time) rather than floating-point seconds.
- Preserve source assets and store edit operations separately.
- Include migration rules, portable relative paths, checksums, autosave journal and recovery snapshots.

## Security, consent and privacy

- No voice cloning without authenticated ownership or explicit authorization from the voice owner.
- Record consent version, scope, timestamp and revocation; provide deletion of profile and source samples.
- Encrypt sensitive voice samples at rest and in transit; restrict access and retention.
- Add abuse reporting, rate limits, audit records, provenance labeling and account recovery controls before public cloning release.
- Never market the tool for impersonation, fraud or non-consensual synthetic speech.
- Recording indicators and microphone permission state must be visible.

## Delivery phases and acceptance gates

### Phase 0 — Voice product foundation
- Lock the product direction to professional voice and audio production.
- Define session schema, audio-engine capability contract and UI navigation.
- Add accurate feature readiness and diagnostics.
- Gate: app loads and reports only capabilities that exist; session schema round-trips through tests.

### Phase 1 — Recording and session editor
- Real microphone capture/playback, file import, input meters, waveform cache and session save/load.
- Multi-track timeline, trim/split/fade, clip gain, mute/solo and undo/redo.
- Gate: record multiple tracks, reopen the project and export a synchronized mix.

### Phase 2 — Voice DSP
- Audio graph, EQ, compressor, gate, de-esser, limiter, fades and offline render.
- Add noise cleanup only with measurable quality tests.
- Gate: golden audio fixtures verify filter response, gain, dynamics, clipping and preview/export parity.

### Phase 3 — AI speech generation
- First cloud TTS provider, script editor, generation queue and audio library.
- Optional offline TTS after platform benchmarks.
- Gate: real generated audio, provider failure handling, cancellation and language-specific pronunciation tests.

### Phase 4 — Dubbing and authorized voice profiles
- ASR/transcript edit, translation review, timing alignment, subtitle export and consent flows.
- Voice profile enrollment only after account security, consent, revocation and deletion are complete.
- Gate: end-to-end reviewed dub with permission/provenance audit trail.

### Phase 5 — Mix, master and live voice
- Buses, sends, automation, loudness metering, mastering presets and stem export.
- Desktop live routing and platform integrations.
- Gate: measured loudness/true peak targets, stable device reconnect and latency tests.

### Phase 6 — Release quality
- CPU/memory profiling, large-session stress tests, project recovery, signed installers and platform QA.
- Codec/license audit, accessibility, privacy review and release notes.
- Gate: repeatable builds and tested workflows on each supported platform.

## Implementation status (November 19, 2026)

### Implemented in source
- Versioned Flutter session model with sample-frame clip positions, tracks, markers, per-clip fades, validation and JSON round-trip tests.
- Professional Voice Studio dashboard with an honest native-library availability indicator.
- Rust offline PCM WAV engine: PCM 8/16/24/32 and IEEE float32 WAV import; mono/stereo buffers; sample-frame clip placement; multitrack mixing; track/clip/master gain; panning; mute/solo; linear fades; sample-peak and overload reporting; PCM 16/24/32 WAV export.
- CPAL microphone input enumeration with persistent device ids and default-input identification.
- CPAL WAV playback through the default output device, using a compatible device-supported sample-rate configuration, common device format conversion, playback position, completion/error status, a 250 ms output-drain tail and explicit stop.
- CPAL mono/stereo microphone capture stream with preallocated lock-free SPSC ring, dropped-frame counter and stream-error status.
- C ABI functions for listing inputs, starting/pausing/reading/stopping capture, and starting/querying/stopping WAV playback; Dart FFI wrappers expose capture and playback session handles.
- Flutter Studio UI for one-take local 24-bit PCM WAV recording, live Peak/RMS meters, a dropped-frame warning, and Play/Stop preview with progress.
- Local Audio Library with RIFF metadata scan, recording search/sort, latest-take playback, rename and confirmed deletion guarded to the recordings directory.
- Versioned C ABI, public C header, engine error reporting and an end-to-end Rust FFI unit test.
- Flutter FFI adapter with ABI checks, asset/track/clip marshaling, output-buffer ownership handling, worker-isolate rendering and a web/unsupported-platform fallback.
- Desktop build workflow steps to compile and copy the native shared library beside Linux, Windows and macOS executables.

### Still not implemented
- Take management, non-destructive session asset registration, pause/resume/punch-in and multitrack playback transport.
- Output-device selection, seek/pause/loop transport, live input-to-output monitoring, device reconnect and end-to-end latency measurements.
- Sample-rate conversion and additional microphone sample formats.
- Android/iOS native audio library packaging and native app linking.
- In-app media-file import UX, waveform display/editor and session-to-render controls.
- Sample-rate conversion, compressed MP3/AAC/FLAC decoders, realtime DSP and waveform cache.
- Production TTS, voice cloning, transcription, translation, dubbing and mastering workflows.

All code and build configuration are committed to `main`. CI still needs to pass before treating the CPAL capture/playback modules, C ABI, Dart FFI adapter and desktop bundling steps as verified end to end. On a desktop build with the matching native library, Studio can capture a microphone take into a standalone local 24-bit PCM WAV, show Peak/RMS meters and dropped-frame warnings, and play the saved WAV through the default output device. The complete session editor, multitrack preview, output-device selection, seek/pause and live input monitoring remain unavailable.
