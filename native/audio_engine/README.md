# Aura Audio Engine

The native-engine foundation for Aura Voice Studio combines deterministic offline PCM WAV rendering, CPAL-based microphone capture and CPAL-based WAV playback, exposed through Rust and a versioned C ABI.

## Implemented

- Decode PCM integer WAV (8/16/24/32-bit) and IEEE float32 WAV.
- Validate mono/stereo buffers, sample rates and frame alignment.
- Arrange clips at exact sample-frame positions.
- Mix tracks using clip/track/master gain, pan, mute, solo and clip fades.
- Report sample peak and samples over full scale before export.
- Export integer PCM WAV at 16/24/32-bit.
- C ABI for creating/destroying render sessions, loading WAV assets, adding tracks/clips, rendering output and releasing returned buffers.
- Public C header at `include/aura_audio_engine.h`.
- Cross-platform microphone input enumeration with stable device ids and default-device reporting.
- Flutter Record Booth input meters and local 24-bit PCM WAV writer with streamed chunk writes and finalized RIFF headers.
- Live mono/stereo microphone capture at the input device's default sample rate.
- A preallocated SPSC sample ring. The audio callback does not allocate, lock, or write files; overflow is reported as dropped frames.
- C ABI capture start/pause/read/status/stop lifecycle and Dart FFI wrappers for device listing and capture reads.
- Native WAV playback via the default output device, with exact sample-rate matching, realtime output callbacks, playback position/status and stop.
- Studio Play/Stop preview controls for saved local takes, plus elapsed-time and progress display.

## Build the shared library

```bash
cargo build --release
```

Outputs are written under `target/release`:
- Windows: `aura_audio_engine.dll`
- macOS: `libaura_audio_engine.dylib`
- Linux: `libaura_audio_engine.so`

The shared library must be placed beside the Flutter desktop executable (or on the platform loader path). The Flutter service checks the ABI version before calling it.

## Test

```bash
cargo test --all-targets
```

## Current limitations

The current Record Booth is a single-take recorder, not a full session recorder. It records to a standalone 24-bit PCM WAV file in the user's Documents folder and can audition that saved file through the default output device. Output-device selection, seek/pause, repeat/loop, live input-to-output monitoring, multitrack playback, waveform display, session asset registration, resampling, compressed formats and realtime DSP remain future work. WAV preview loads the entire file into memory and is limited to 256 MiB in the Flutter app; the system output device must support the file sample rate. Device reconnect and low-latency measurements also remain future work.
