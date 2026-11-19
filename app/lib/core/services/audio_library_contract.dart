/// Metadata for a local WAV recording managed by Aura Voice Studio.
class AudioLibraryRecording {
  const AudioLibraryRecording({
    required this.path,
    required this.name,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.duration,
    required this.frameCount,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });

  final String path;
  final String name;
  final DateTime modifiedAt;
  final int sizeBytes;
  final Duration duration;
  final int frameCount;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
}

/// Local recording library backed by the user's Recordings directory.
abstract interface class AudioLibraryService {
  String get directoryPath;

  Future<List<AudioLibraryRecording>> listRecordings();

  Future<AudioLibraryRecording> renameRecording(
    AudioLibraryRecording recording,
    String newName,
  );

  Future<void> deleteRecording(AudioLibraryRecording recording);
}

class AudioLibraryUnavailable implements Exception {
  const AudioLibraryUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
