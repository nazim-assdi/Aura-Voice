import 'dart:typed_data';

/// Compact peak data derived from the original WAV samples.
class AudioWaveformData {
  AudioWaveformData({
    required List<double> peaks,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.frameCount,
  }) : peaks = Float32List.fromList(peaks);

  final Float32List peaks;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int frameCount;

  Duration get duration => Duration(
        microseconds: (frameCount * 1000000 / sampleRate).round(),
      );
}

abstract interface class AudioWaveformService {
  Future<AudioWaveformData> analyze(
    String path, {
    int peakCount = 320,
  });
}

class AudioWaveformUnavailable implements Exception {
  const AudioWaveformUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
