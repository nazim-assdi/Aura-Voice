import 'dart:typed_data';

import '../../features/session/models/audio_session.dart';

/// Result of an offline session render.
class AudioRenderResult {
  const AudioRenderResult({
    required this.wavBytes,
    required this.samplePeak,
    required this.clippedSamples,
  });

  final Uint8List wavBytes;
  final double samplePeak;
  final int clippedSamples;
}

/// A physical or virtual input exposed by the current operating system.
class AudioInputDevice {
  const AudioInputDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.channels,
    required this.sampleRate,
  });

  final String id;
  final String name;
  final bool isDefault;
  final int channels;
  final int sampleRate;
}

/// A physical or virtual output exposed by the current operating system.
class AudioOutputDevice {
  const AudioOutputDevice({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.channels,
    required this.sampleRate,
    required this.minSampleRate,
    required this.maxSampleRate,
  });

  final String id;
  final String name;
  final bool isDefault;
  final int channels;
  final int sampleRate;
  final int minSampleRate;
  final int maxSampleRate;
}

/// Handle for a running microphone capture stream.
///
/// Samples are interleaved float32 PCM in the device's native sample rate.
/// A consumer must drain the stream regularly and check [droppedFrames].
abstract interface class AudioCaptureSession {
  int get sampleRate;
  int get channels;
  int get droppedFrames;
  bool get hasError;

  Future<void> pause();

  Future<Float32List> readFrames({int maxFrames = 2048});

  Future<void> stop();
}

/// Handle for a direct microphone-to-output monitor stream.
abstract interface class AudioMonitorSession {
  int get inputSampleRate;
  int get outputSampleRate;
  int get underrunFrames;
  bool get hasError;

  Future<void> setGain(double gain);
  Future<void> stop();
}

/// Handle for an operating-system audio playback stream.
abstract interface class AudioPlaybackSession {
  int get sampleRate;
  int get totalFrames;
  int get positionFrames;
  bool get isComplete;
  bool get hasError;
  bool get isPaused;

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int frame);

  /// Enables or disables a sample-frame loop range. When enabled,
  /// [startFrame] must be lower than [endFrame] and inside the rendered mix.
  Future<void> setLoopRange({
    required int startFrame,
    required int endFrame,
    required bool enabled,
  });

  /// Replaces the active immutable session graph without stopping transport.
  /// The output callback switches snapshots at the next audio block boundary.
  Future<void> replaceSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
  });

  Future<void> stop();
}

/// Abstraction over the optional native audio engine.
abstract interface class AudioEngineService {
  bool get isAvailable;

  /// Renders a session from WAV assets keyed by each clip's mediaId.
  ///
  /// Assets must already match the session sample rate.
  Future<AudioRenderResult> renderSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    int? bitDepth,
  });

  /// Starts direct callback-driven multitrack playback from a session.
  ///
  /// Source WAVs are decoded and the playback graph is prepared before opening
  /// the output device. The native callback mixes clip buffers at the current
  /// sample frame; it does not render a complete intermediate WAV.
  Future<AudioPlaybackSession> startRealtimePlayback({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    String? outputDeviceId,
  });

  /// Returns the current OS microphone devices using stable platform ids.
  Future<List<AudioInputDevice>> listInputDevices();

  /// Returns the current OS output devices and their supported rate range.
  Future<List<AudioOutputDevice>> listOutputDevices();

  /// Opens input and output streams and bridges their clocks using a
  /// preallocated ring buffer. Use headphones to avoid acoustic feedback.
  Future<AudioMonitorSession> startMonitor({
    String? inputDeviceId,
    String? outputDeviceId,
    int bufferMilliseconds = 30,
    double gain = 1.0,
  });

  /// Starts a capture stream. A null deviceId selects the OS default input.
  Future<AudioCaptureSession> startCapture({
    String? deviceId,
    int bufferMilliseconds = 1000,
  });

  /// Plays a PCM or IEEE-float WAV through the default OS output device.
  ///
  /// The output device must support the WAV's sample rate. The native engine
  /// reports a clear error instead of playing at the wrong speed.
  Future<AudioPlaybackSession> startPlayback({
    required Uint8List wavBytes,
  });
}

class AudioEngineUnavailable implements Exception {
  const AudioEngineUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
