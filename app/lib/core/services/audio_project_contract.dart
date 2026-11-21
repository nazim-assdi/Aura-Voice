import '../../features/session/models/audio_session.dart';

class AudioProjectIntegrityReport {
  const AudioProjectIntegrityReport({
    required this.checkedAssetCount,
    required this.missingMediaPaths,
    required this.corruptMediaPaths,
    required this.hasChecksumManifest,
  });

  final int checkedAssetCount;
  final List<String> missingMediaPaths;
  final List<String> corruptMediaPaths;
  final bool hasChecksumManifest;

  bool get isValid =>
      missingMediaPaths.isEmpty && corruptMediaPaths.isEmpty;
}

class AudioProjectVersionSummary {
  const AudioProjectVersionSummary({
    required this.path,
    required this.label,
    required this.createdAt,
    required this.trackCount,
    required this.sampleRate,
  });

  final String path;
  final String label;
  final DateTime createdAt;
  final int trackCount;
  final int sampleRate;
}

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

  /// Copies every referenced source WAV beside the manifest and saves
  /// portable, project-relative media references.
  Future<String> savePortable(AudioSession session);

  /// Checks whether a referenced local media file is currently available.
  Future<bool> mediaExists(String path);

  /// Checks the media references and SHA-256 inventory for a portable project.
  Future<AudioProjectIntegrityReport> verifyPortableProject(String path);

  /// Writes a verified portable project manifest and its assets to a ZIP file.
  Future<String> exportPortableArchive(String projectPath, String zipPath);

  /// Safely imports a ZIP project into the managed Projects directory.
  Future<String> importPortableArchive(String zipPath);

  /// Creates a lightweight immutable version manifest sharing content-addressed media.
  Future<String> createProjectVersion(String projectPath, {String? label});

  Future<List<AudioProjectVersionSummary>> listProjectVersions(
    String projectPath,
  );

  /// Restores a version after validating all referenced media and checksums.
  Future<String> restoreProjectVersion(
    String projectPath,
    String versionPath,
  );

  Future<void> deleteProjectVersion(
    String projectPath,
    String versionPath,
  );

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
