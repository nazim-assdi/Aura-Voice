# Aura Audio Engine

Aura Voice Studio's native Rust engine provides offline PCM WAV rendering, CPAL microphone capture, standalone WAV audition and callback-driven realtime multitrack playback. The native library is exposed to Flutter through C ABI version 4.

## Implemented

- Decode PCM integer WAV (8/16/24/32-bit) and IEEE float32 WAV.
- Validate mono/stereo buffers, sample rates and frame alignment.
- Arrange clips at exact sample-frame positions.
- Mix tracks using clip/track/master gain, pan, mute, solo and clip fades.
- Report sample peak and samples over full scale before export.
- Export integer PCM WAV at 16/24/32-bit.
- Enumerate operating-system microphone inputs with stable device ids and default-device reporting.
- Capture mono/stereo microphone streams at the input device's default sample rate.
- Use a preallocated single-producer/single-consumer ring: the audio callback performs no file I/O, heap allocation or blocking lock operation; ring overflow is counted.
- Record a single local take from Flutter into a 24-bit PCM WAV file. The UI drains the ring outside the device callback, shows Peak/RMS meters and reports dropped frames.
- Pause capture, flush buffered samples, finalize the WAV header and stop the input stream on Finish & Save.
- Local Audio Library reads RIFF metadata without loading the WAV payload, and its waveform analyzer scans samples in bounded 64 KiB chunks to build peak buckets.
- A local project manifest store saves sample-frame sessions in JSON, uses backup/restore when updating an existing manifest, and can locate source WAV paths referenced by clips.
- The Flutter multitrack editor can arrange and non-destructively edit sample-frame clips, show source-aligned waveform lanes, set track mute/solo and clip gain/mute, save/reopen sessions and play the session through the realtime native mixer. Playhead, seek, pause/resume, whole-mix loop and selected-clip loop use the same sample-frame transport.
- Play a standalone PCM/IEEE-float WAV through the default OS output device using CPAL. Its callback uses an atomic compare-exchange cursor for seek, pause/resume and loop ranges.
- Prepare a multitrack session off the audio thread: decode each referenced WAV once, validate sample rate/source ranges, precompute pan coefficients and move decoded PCM into immutable shared buffers. The output callback mixes active clips directly at each sample frame, applying track/clip gain, pan, mute/solo and edge fades with no heap allocation, blocking lock or file I/O. It exposes the same position/completion/error and loop transport.
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

The shared library must be placed beside the Flutter desktop executable (or on the platform loader path). The Dart service checks C ABI version 4 before using it. Desktop CI currently packages the native library next to each generated app executable; check the workflow result before treating a release build as verified.

## Current limitations

The Record Booth still creates standalone 24-bit PCM WAV takes under `Documents/Aura Voice Studio/Recordings`. The editor stores clip references by local source path and keeps source WAVs unchanged. A complete take lane/punch-in workflow, project asset import/copy and media-relink recovery are not yet implemented.

Playback currently uses only the default output device and requires the device to support the session sample rate; resampling and output-device selection are not implemented. Realtime playback prepares an immutable graph before opening CPAL and then mixes directly in the output callback. The initial scheduler scans each track's clip list per output frame, so very dense-session CPU/underrun benchmarks and block-based scheduling optimization remain necessary. Dynamic graph edits while playback is running, live input monitoring, realtime DSP/effects, buses/sends and physical-device validation on Windows/macOS/Linux remain future work.

Input-to-output monitoring, live effects, device reconnect recovery, output latency calibration, more microphone sample formats, trim/crossfade editing, undo/redo, autosave, media relinking, compressed MP3/AAC/FLAC decoding, resampling, realtime DSP and persistent waveform caches remain future work. Android/iOS native library packaging and audio-session integration are also not complete.
