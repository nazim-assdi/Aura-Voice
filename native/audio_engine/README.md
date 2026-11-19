# Aura Audio Engine

The first native-engine milestone for Aura Voice Studio is a dependency-free Rust library for deterministic **offline PCM WAV rendering**.

## Implemented in this milestone

- Decode RIFF/WAVE PCM integer audio at 8/16/24/32 bits and IEEE float32 audio.
- Validate mono/stereo sample buffers, sample rates and frame alignment.
- Arrange clips on exact sample-frame positions.
- Mix multiple tracks with clip/track/master gain, pan, mute and solo.
- Apply linear clip fade-in and fade-out envelopes.
- Report sample peak and samples exceeding full scale before export.
- Export interleaved PCM WAV at 16/24/32 bits.

## Deliberate limits

This crate does not yet capture a microphone, play audio through a device, resample, decode compressed MP3/AAC/FLAC, provide realtime effects, or perform true-peak/loudness analysis. Assets must be decoded to the session sample rate before mixing. Export does not silently normalize; it reports overload and clamps only when quantizing the WAV file.

## Run tests

```bash
cd native/audio_engine
cargo test
```

This is the offline render core only. Platform audio I/O and the stable Flutter FFI bridge are separate upcoming milestones.
