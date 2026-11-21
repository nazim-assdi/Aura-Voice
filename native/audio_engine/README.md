# Aura Audio Engine

Aura Voice Studio's native Rust engine provides offline PCM WAV rendering, CPAL microphone capture, standalone WAV audition and callback-driven realtime multitrack playback. The native library is exposed to Flutter through C ABI version 6.

## Implemented

- Decode PCM integer WAV (8/16/24/32-bit) and IEEE float32 WAV.
- Validate mono/stereo buffers, sample rates and frame alignment.
- Arrange clips at exact sample-frame positions.
- Mix tracks using clip/track/master gain, pan, mute, solo and clip fades.
- Report sample peak and samples over full scale before export.
- Export integer PCM WAV at 16/24/32-bit.
- Enumerate operating-system microphone inputs with stable device ids and default-device reporting.
- Enumerate operating-system output devices with stable ids, default-device reporting, channel capability and supported sample-rate ranges; open the selected output device for realtime multitrack playback and standalone WAV preview.
- Convert session assets and sample-frame clip/fade positions to the negotiated output sample rate before opening the realtime stream. Standalone WAV preview is also converted before stream creation. The worker-side asset converter uses a windowed-sinc low-pass resampler; it does not run in the audio callback.
- The Studio exposes a direct microphone-to-output monitor with independent CPAL input/output streams, requested low-latency CPAL callback buffers where the host exposes a supported range, a preallocated SPSC bridge, linear clock conversion, a bounded occupancy servo, monitor gain, input-drop count and output ring-starvation count.
- The monitor reports the best available input/output callback sizes, input capture-to-callback and output callback-to-predicted-playback timestamp durations, plus a host-timestamp estimate for capture-to-predicted-DAC handoff. It keeps the requested buffer size and actual/observed callback sizes distinct. The estimate is not a calibrated electrical round-trip measurement.
- The multitrack Editor exposes callback count, processed frames, estimated callback CPU, maximum callback time and software deadline misses. These metrics do not report hardware round-trip latency or the device driver's underrun counter.
- Capture mono/stereo microphone streams at the input device's default sample rate.
- Use a preallocated single-producer/single-consumer ring: the audio callback performs no file I/O, heap allocation or blocking lock operation; ring overflow is counted.
- Record a single local take from Flutter into a 24-bit PCM WAV file. The UI drains the ring outside the device callback, shows Peak/RMS meters and reports dropped frames.
- Pause capture, flush buffered samples, finalize the WAV header and stop the input stream on Finish & Save.
- Local Audio Library reads RIFF metadata without loading the WAV payload, and its waveform analyzer scans samples in bounded 64 KiB chunks to build peak buckets.
- A local project manifest store saves sample-frame sessions in JSON, uses backup/restore when updating an existing manifest, and can locate source WAV paths referenced by clips.
- The Flutter multitrack editor can arrange and non-destructively edit sample-frame clips, show source-aligned waveform lanes, set track mute/solo and clip gain/mute, save/reopen sessions and play the session through the realtime native mixer. Playhead, seek, pause/resume, whole-mix loop and selected-clip loop use the same sample-frame transport.
- Play a standalone PCM/IEEE-float WAV through a selected OS output device using CPAL, with windowed-sinc resampling before stream creation and a requested 10 ms callback buffer when the device exposes a supported range. Its callback uses an atomic compare-exchange cursor for seek, pause/resume and loop ranges.
- Prepare a multitrack session off the audio thread: decode each referenced WAV, validate sample rate/source ranges, precompute pan/fade coefficients and move decoded PCM into immutable shared buffers.
- Run the CPAL output callback with a preallocated event-based block scheduler (up to 1024 frames per block). Sorted clip start/end events maintain an active-clip set, so each sample frame mixes only currently active clips rather than scanning every clip in the project. The callback allocates no memory, performs no blocking lock or file I/O, and applies clip/track/master gain, pan, mute/solo and fades.
- Publish replacement immutable graphs while playback remains active. The UI/worker prepares and validates the new graph; a hazard-pointer handoff lets the callback switch snapshots at the next block boundary without waiting on the publisher lock or freeing graph memory on the audio thread.
- Apply per-track realtime high-pass filtering and an envelope-based compressor with configurable cutoff, threshold and ratio. The same settings are applied by the offline renderer for preview/export parity.
- Studio Play/Stop controls and progress for the most recent saved take.
- Versioned C ABI and public C header in `include/aura_audio_engine.h`.

## Build the shared library

On Linux, install the ALSA build dependencies first:

```bash
sudo apt-get update
sudo apt-get install -y libasound2-dev pkg-config
```

Then build from this directory:

```bash
cargo check --all-targets
cargo test --all-targets
cargo build --release
```

Outputs are written under `target/release`:
- Windows: `aura_audio_engine.dll`
- macOS: `libaura_audio_engine.dylib`
- Linux: `libaura_audio_engine.so`

The shared library must be placed beside the Flutter desktop executable (or on the platform loader path). The Dart service checks C ABI version 6 before using it. Desktop CI currently packages the native library next to each generated app executable; check the workflow result before treating a release build as verified.

## Current limitations

The Record Booth still creates standalone 24-bit PCM WAV takes under `Documents/Aura Voice Studio/Recordings`. The editor stores clip references by local source path and keeps source WAVs unchanged. A complete take lane/punch-in workflow, project asset import/copy and media-relink recovery are not yet implemented.

Realtime multitrack playback and standalone WAV audition can both select an enumerated OS output device. Project PCM and standalone WAV sources are converted to the negotiated device rate before opening the stream; transport positions are mapped back to the source/project sample-rate clock. The standalone preview requests an approximately 10 ms callback buffer when the host exposes a supported range. The event-based scheduler processes blocks up to 1024 frames and maintains sorted clip start/end events plus a preallocated active-clip set. Live graph updates switch at the next callback block and are prepared at the active output rate.

The direct microphone monitor uses separate input and output streams and a short preallocated ring bridge. A linear interpolator and bounded occupancy servo bridge independent input/output sample clocks. The requested monitor buffer size now also requests CPAL input/output callback sizes where the device reports a supported range; after stream creation, the engine queries the best available stream buffer size and tracks observed callback blocks as a fallback. The UI distinguishes requested milliseconds, ring capacity, callback block sizes and a CPAL host-timestamp estimate built from input capture-to-callback time, app handoff time and output callback-to-predicted-playback time. Ring starvation/input drops remain separate from driver underruns. The host-timestamp estimate is not calibrated electrical round-trip latency; physical loopback tests on Windows/macOS/Linux are still required. Follow [docs/HARDWARE_AUDIO_BENCHMARK.md](../../docs/HARDWARE_AUDIO_BENCHMARK.md).

Device reconnect recovery, output latency calibration, more microphone sample formats, advanced effects beyond the current high-pass/compressor, buses/sends, media relinking, compressed MP3/AAC/FLAC decoding and persistent waveform caches remain future work. Android/iOS native library packaging and audio-session integration are also not complete.
