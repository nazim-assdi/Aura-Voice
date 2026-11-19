import 'dart:typed_data';

/// Streams interleaved float32 capture samples into a local PCM WAV file.
abstract interface class AudioRecordingWriter {
  bool get isOpen;
  String? get filePath;

  Future<void> start({
    required int sampleRate,
    required int channels,
    String? directoryPath,
  });

  Future<void> append(Float32List interleavedSamples);

  /// Finalizes the WAV header, closes the file and returns its path.
  Future<String> finish();

  /// Closes and deletes the partial recording.
  Future<void> discard();
}

class AudioRecordingUnavailable implements Exception {
  const AudioRecordingUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
