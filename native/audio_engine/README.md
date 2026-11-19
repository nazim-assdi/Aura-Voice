# Aura Audio Engine

Aura Voice Studio's native Rust engine provides offline PCM WAV rendering, CPAL microphone capture and CPAL WAV playback. The native library is exposed to Flutter through C ABI version 2.

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
- The current Flutter multitrack editor can arrange sample-frame clips from the library, show real waveform lanes, set track mute/solo and clip gain/mute, remove clips non-destructively, save/reopen sessions and render/play an offline mix.
- Play a saved PCM/IEEE-float WAV through the default OS output device using CPAL. The output stream uses a supported configuration at the WAV's sample rate, converts common device sample formats in the output callback, and exposes playback position, completion/error status, a 250 ms output-drain tail and stop.
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

The shared library must be placed beside the Flutter desktop executable (or on the platform loader path). The Dart service checks C ABI version 2 before using it. Desktop CI currently packages the native library next to each generated app executable; check the workflow result before treating a release build as verified.

## Current limitations

The Record Booth still creates standalone 24-bit PCM WAV takes under `Documents/Aura Voice Studio/Recordings`. The editor stores clip references by local source path and keeps source WAVs unchanged. A complete take lane/punch-in workflow, project asset import/copy and media-relink recovery are not yet implemented.

Playback currently uses only the default output device. Single-take and editor mix preview decode/render to memory and play through the default device; a source preview WAV is limited to 256 MiB and output requires a supported sample rate. The editor preview renders the current session offline before playback; it is not real-time multitrack transport. There is no resampling, output-device picker, seek, pause, loop, volume automation or continuous timeline playback. The output callback is designed to avoid allocation/locking, but playback has not yet been validated on physical Windows/macOS/Linux audio devices in CI.

Input-to-output monitoring, live effects, device reconnect recovery, output latency calibration, more microphone sample formats, trim/split/fade/crossfade editing, undo/redo, autosave, media relinking, compressed MP3/AAC/FLAC decoding, resampling, realtime DSP and persistent waveform caches remain future work. Android/iOS native library packaging and audio-session integration are also not complete.
