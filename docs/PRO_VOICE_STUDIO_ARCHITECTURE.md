# Aura Voice Studio — Product Architecture & Delivery Plan

## Product direction

**Aura Voice** is a professional voice-production and audio-workstation application. It is not a video editor. The product combines a recording booth, multitrack voice editor, AI speech studio, dubbing workspace, audio restoration tools and a mastering suite.

The full production workspace is desktop-first (Windows, macOS and Linux). Android and iOS provide voice recording, script/TTS workflows, review, light edits and project handoff. A consistent project format keeps sessions portable across supported platforms.

This repository is an early Flutter/FastAPI/native-engine foundation. Source includes local 24-bit PCM recording and audition plus a non-destructive sample-frame editor with waveform clips, trim/split, crossfade, snap grid, timeline zoom, bounded undo/redo and autosave. The native callback-driven mixer uses an event-based block scheduler, updates immutable graph snapshots during playback, performs worker-side sample-rate conversion to a selected output device, and provides per-track high-pass/compressor processing. Studio also contains a direct microphone-to-output monitoring path. Physical-device performance/round-trip latency validation, device reconnect recovery, advanced DSP, production TTS, voice cloning, dubbing and mastering remain in development.

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

The current implementation of native output uses a sample-frame transport and no full render WAV intermediate.
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

## Implementation status (November 21, 2026)

### Implemented in source
- Versioned Flutter session model with sample-frame clip positions, tracks, markers, per-clip fades, validation and JSON round-trip tests.
- Professional Voice Studio dashboard with an honest native-library availability indicator.
- Rust PCM WAV engine: PCM 8/16/24/32 and IEEE float32 WAV import; mono/stereo buffers; sample-frame clip placement; offline multitrack mix; track/clip/master gain; panning; mute/solo; linear fades; per-track high-pass and compressor processing; sample-peak/overload reporting; PCM 16/24/32 WAV export.
- CPAL microphone input enumeration with persistent device ids and default-input identification.
- CPAL standalone WAV playback through a selected output device, with worker-side windowed-sinc resampling to the negotiated device sample rate, a requested 10 ms callback buffer where supported, common device format conversion, atomic sample-frame cursor, pause/resume, seek, validated loop range, playback position, completion/error status, a 250 ms output-drain tail and explicit stop.
- CPAL output-device discovery/selection for realtime multitrack playback and standalone WAV audition, including supported-rate discovery and worker-side windowed-sinc resampling with clip/timeline frame conversion to the negotiated output rate.
- Direct CPAL microphone-to-output monitoring with a preallocated SPSC bridge, input/output clock interpolation, bounded occupancy servo, monitor gain and separate input-drop/output-starvation counters. It requests small CPAL callback sizes within the host's supported buffer range, reports the best available actual stream/callback block sizes and separates SPSC ring capacity from device callback size.
- Host-timestamp latency diagnostics combine input capture-to-callback duration, monotonic app handoff time and output callback-to-predicted-playback duration. Studio displays this estimate and its maximum, plus the input and output timestamp components; it is an API estimate, not a physical loopback calibration.
- Realtime callback telemetry exposed to the Editor: callback count, processed frames, estimated callback CPU, maximum callback duration and software block-deadline misses. These metrics are not a driver underrun counter or calibrated end-to-end latency measurement.
- CPAL mono/stereo microphone capture stream with preallocated lock-free SPSC ring, dropped-frame counter and stream-error status.
- C ABI version 6 for input/output discovery, capture, direct monitoring and its buffer/latency diagnostics, standalone WAV audition with device selection and sample-rate conversion, callback-driven realtime session playback, output-rate negotiation, live session-graph replacement, track DSP configuration and shared sample-frame transport; Dart FFI exposes capture, monitor and playback handles.
- Flutter Studio UI for one-take local 24-bit PCM WAV recording, live Peak/RMS meters, a dropped-frame warning, and Play/Stop preview with progress.
- Local Audio Library with RIFF metadata scan, sample-frame duration, recording search/sort, saved-take playback, true sample-derived waveform preview, rename and confirmed deletion guarded to the canonical recordings directory. Recordings referenced by saved projects are protected.
- Local JSON session-project store with backup/restore on interrupted replacement, project listing/reopen and source-media reference checks.
- Early non-destructive multitrack editor with sample-frame ruler/source waveforms; long-press movement and edge trim; split/crossfade; configurable 10 ms–1 s snap grid; 25%–400% zoom; bounded 100-entry undo/redo; debounced autosave; clip gain/fades/mute; track mute/solo; selected-track high-pass/compressor controls; session save/reopen; and realtime playhead/seek/pause/resume/whole-mix/selected-clip loop.
- Versioned C ABI, public C header, engine error reporting and an end-to-end Rust FFI unit test.
- Flutter FFI adapter with ABI checks, WAV/track/clip/DSP marshaling, worker-isolate export and realtime graph preparation/replacement, native handle-lifetime protection and web/unsupported-platform fallback.
- Desktop build workflow steps to compile and copy the native shared library beside Linux, Windows and macOS executables.

### Still not implemented
- Take management, non-destructive media relinking, project asset import/copy strategy and recovery snapshots.
- Device reconnect recovery, physical loopback calibration and physical-device CPU/deadline/driver-underrun benchmarks for dense sessions. Software callback metrics, actual/observed callback block sizes and CPAL host-timestamp monitor estimates are available, but do not substitute for calibrated electrical round-trip latency or driver underrun measurements.
- Android/iOS native audio library packaging and native app linking.
- Waveform-cache persistence, portable media relinking, project asset copy/import strategy, crash-recovery snapshots, and edit operations that persist as a journal rather than only in-memory undo history. Current trim is inward-only because source-media end boundaries are not yet stored in the project schema.
- Advanced realtime effects beyond the current high-pass/compressor lane, buses/sends, compressed MP3/AAC/FLAC decoders, persistent waveform cache and production audio restoration.
- Production TTS, voice cloning, transcription, translation, dubbing and mastering workflows.

All code and build configuration are committed directly to the existing `main` branch. The native Audio Engine CI for commit `2286a22c` completed successfully: `cargo check`, shared-library build and all 32 deterministic Rust tests passed. That validated the standalone WAV output selection/resampling, runtime monitor buffer-size queries and OS-default buffer fallback in the native engine. Flutter Analyze/widget tests and platform builds are still under CI verification for the Dart/Flutter integration. Real-device validation is still required before the output path is considered hardware-performance-verified. Source now includes output-device selection, worker-side rate conversion, direct microphone monitoring and software callback diagnostics. These diagnostics do not establish actual driver underruns or input-to-output latency. Follow [the real-device benchmark runbook](HARDWARE_AUDIO_BENCHMARK.md) to record Windows/macOS/Linux measurements. Advanced DSP and mobile native audio packaging remain outstanding.
