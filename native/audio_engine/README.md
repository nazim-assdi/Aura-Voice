# Aura Audio Engine

The first native-engine milestone for Aura Voice Studio is a dependency-free Rust library for deterministic offline PCM WAV rendering, exposed through both a Rust API and a C ABI.

## Implemented

- Decode PCM integer WAV (8/16/24/32-bit) and IEEE float32 WAV.
- Validate mono/stereo buffers, sample rates and frame alignment.
- Arrange clips at exact sample-frame positions.
- Mix tracks using clip/track/master gain, pan, mute, solo and clip fades.
- Report sample peak and samples over full scale before export.
- Export integer PCM WAV at 16/24/32-bit.
- C ABI for creating/destroying render sessions, loading WAV assets, adding tracks/clips, rendering output and releasing returned buffers.
- Public C header at `include/aura_audio_engine.h`.

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

The engine is an offline renderer, not a live recording engine. It does not yet capture microphone input, play through audio devices, resample, decode compressed MP3/AAC/FLAC, or provide realtime DSP. Input assets must already be WAV and match the session sample rate. The current mixer supports mono/stereo output.
