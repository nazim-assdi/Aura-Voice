# Real-device audio performance benchmark

## Purpose

This runbook validates the realtime mixer and the direct microphone monitor on actual audio hardware. It is deliberately separate from deterministic unit tests: an 8,192-clip scheduling test proves scheduler correctness for its fixture, not device latency, callback deadlines or hardware underruns.

The current engine exposes software callback diagnostics and monitor-ring counters. These help identify regressions, but they do not reveal the complete driver/hardware signal path.

## Required test machines

Run the same benchmark on at least one physical machine for each desktop target:

| Platform | Device path to record |
|---|---|
| Windows | CPAL host/backend, WASAPI device name and driver version |
| macOS | Core Audio device name, macOS version and device firmware/driver details if available |
| Linux | CPAL host/backend (ALSA/PipeWire/PulseAudio as reported), device name, kernel and audio-server version |

Use both a built-in audio device and a USB interface where possible. Record the exact input and output device ids reported by Aura Voice. Keep power mode, connected peripherals, audio-server configuration and background workload stable between comparisons.

## Mixer playback procedure

1. Build a release desktop app and native library from the same commit. Record the commit SHA, OS build, CPU model, RAM, native library version and Aura audio ABI version (currently v6).
2. Select a physical output device in the Multitrack Editor and in the Voice Studio/Audio Library standalone WAV preview. Use a session and a WAV source at 44.1 kHz and repeat at 48 kHz. Also test source/project rates that differ from the device's negotiated rate to exercise worker-side windowed-sinc conversion.
3. Create repeatable sessions with 1, 8, 16 and 32 active tracks. Include overlapping clips, short clips, fades, panning and the track high-pass/compressor lane. Keep the audio source files and session manifests identical between machines.
4. Run each session for at least five minutes after a short warm-up. Repeat each case three times. Do not change the device sample rate or sample format while a stream is running.
5. During playback, record the Editor diagnostics: output sample rate, callback count, processed frames, estimated callback CPU percentage, maximum callback duration in microseconds and callback deadline misses.
6. Record any audible clicks/dropouts, playback stalls, device disconnects, UI stalls and whether the problem is repeatable. Capture OS-level CPU usage alongside the app.
7. Repeat with graph updates (track mute/solo, clip edits and DSP parameter changes) while audio is playing. Confirm the stream remains open and note any callback deadline misses around updates.

The callback deadline metric compares a callback's measured execution duration with the nominal audio duration of the block it processed. It is a software deadline indicator, not a driver-provided underrun count. The estimated callback CPU percentage is derived from callback time divided by processed audio time; it is not the same as whole-process or whole-system CPU usage. Instrumentation itself adds a small measurement overhead.

## Live microphone monitoring procedure

1. Connect a physical microphone and headphones. Do not begin with speakers: acoustic feedback can become dangerous and may damage hearing or equipment.
2. Select the input and output devices in Voice Studio and start Live microphone monitor. Record the negotiated input/output sample rates, the requested callback-buffer target (the UI defaults to 20 ms), SPSC ring capacity, queried input/output stream buffer sizes and observed callback block sizes.
3. Speak or play a known test signal for five minutes. Repeat with the same-clock device pair and with devices that negotiate different sample rates.
4. Record the host-timestamp capture-to-predicted-playback estimate (current and maximum), input capture-to-callback time, output callback-to-playback time, output ring-starvation frames and input ring dropped frames. The timestamp estimate sums durations measured within each stream's own clock plus the app handoff measured from one shared monotonic clock; it is not a physical loopback calibration. Ring starvation/input drops report SPSC starvation/overflow, not hardware driver underruns.
5. Repeat after disconnecting/reconnecting a device and after changing the OS default device. Note whether the stream stops cleanly or requires a manual restart.
6. Measure electrical input-to-output round-trip latency using a physical loopback path (for example, line out to line in through suitable equipment) or a validated platform/device latency measurement tool. Record the method and uncertainty. Compare it with the CPAL host-timestamp estimate and document the difference. Do not infer end-to-end latency from the 20 ms callback request or the ring capacity.

The monitor path uses linear interpolation to bridge the input and output sample clocks, with a bounded occupancy servo. The requested 20 ms value now requests both ring capacity and CPAL callback buffer size where supported; the host may clamp/ignore the request, so record queried stream buffer sizes and observed callback sizes. The UI's CPAL host-timestamp estimate includes input capture-to-callback, application handoff and output callback-to-predicted-playback components. It remains an API estimate; OS scheduling, driver period, device safety buffers, converters and clock behavior mean a physical loopback test is still required. The mixer/standalone WAV asset resampler is a separate worker-side windowed-sinc conversion.

## Results to save

For every run, preserve a machine-readable record with:

- commit SHA, ABI version, OS/kernel build, CPU model, memory and app build mode;
- audio host/backend, device model/identifier, driver/firmware version, input/output sample rates and channel layouts;
- project sample rate, active tracks, active clips, effects enabled and duration;
- callback count, processed frames, estimated callback CPU, mean callback time (total callback ns / callback count), maximum callback time and software deadline misses;
- monitor input dropped frames, monitor output ring-starvation frames, negotiated buffer settings and measured round-trip latency with the measurement method;
- OS-level CPU usage, observed glitches, device reconnect results and notes.

Compare identical workloads and disclose the number of repetitions. Report median and worst-run values rather than a single best run. Keep raw logs with the summary.

## Acceptance gates

Do not label the mixer or monitor as hardware-performance-verified until:

- release builds and automated tests pass on the target platform;
- all three repeated workload runs complete without audible glitches or transport stalls;
- callback deadline misses and OS-level CPU are within the project's agreed budget on the target machine;
- the live monitor has no unexplained input drops or output ring starvation during the sustained test;
- end-to-end round-trip latency has been measured independently and meets a published target for the intended use case;
- device removal/reconnect behavior is documented and reproducible.

No real-device results are recorded in this repository yet. CI builds and software tests cannot substitute for this hardware validation.
