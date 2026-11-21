import '../../features/session/models/audio_session.dart';

class AudioProjectSummary {
  const AudioProjectSummary({
    required this.path,
    required this.title,
    required this.modifiedAt,
    required this.sampleRate,
    required this.trackCount,
  });

  final String path;
  final String title;
  final DateTime modifiedAt;
  final int sampleRate;
  final int trackCount;
}

abstract interface class AudioProjectStore {
  String get directoryPath;

  Future<String> save(AudioSession session);

  Future<AudioSession> load(String path);

  Future<List<AudioProjectSummary>> listProjects();

  /// Finds projects whose clips reference a local media path.
  Future<List<AudioProjectSummary>> findProjectsUsingMedia(String mediaPath);

  /// Writes the latest unsaved state to the separate recovery area.
  Future<String> saveRecoverySnapshot(AudioSession session);

  Future<AudioSession> loadRecoverySnapshot(String path);

  Future<List<AudioProjectSummary>> listRecoverySnapshots();

  Future<void> deleteRecoverySnapshot(String path);

  Future<void> delete(String path);
}

class AudioProjectStoreUnavailable implements Exception {
  const AudioProjectStoreUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
