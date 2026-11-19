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

/// Abstraction over the optional native offline audio renderer.
abstract interface class AudioEngineService {
  bool get isAvailable;

  /// Renders a session from WAV assets keyed by each clip's mediaId.
  ///
  /// Rendering is executed away from the Flutter UI isolate by native
  /// implementations. Assets must already match the session sample rate.
  Future<AudioRenderResult> renderSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    int? bitDepth,
  });
}

class AudioEngineUnavailable implements Exception {
  const AudioEngineUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
