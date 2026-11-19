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

  /// Returns the current OS microphone devices using stable platform ids.
  Future<List<AudioInputDevice>> listInputDevices();

  /// Starts a capture stream. A null deviceId selects the OS default input.
  Future<AudioCaptureSession> startCapture({
    String? deviceId,
    int bufferMilliseconds = 1000,
  });
}

class AudioEngineUnavailable implements Exception {
  const AudioEngineUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
