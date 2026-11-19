# Aura Audio Engine

The native-engine foundation for Aura Voice Studio combines deterministic offline PCM WAV rendering with CPAL-based live microphone capture, exposed through Rust and C ABIs.

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
- C ABI capture start/read/status/stop lifecycle and Dart FFI wrappers for device listing and capture reads.

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

Live capture is an input-stream foundation, not yet a complete recording booth. The Flutter studio does not yet expose record/arm/pause controls, continuously drain the capture ring into a project asset, write captured PCM to WAV, or provide live monitor playback. Capture uses the device's default rate/format; unsupported sample formats, resampling, device reconnect recovery, loopback and realtime DSP remain future work. The offline mixer still accepts mono/stereo WAV assets only.
