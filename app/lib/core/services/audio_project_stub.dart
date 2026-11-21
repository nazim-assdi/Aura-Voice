import 'audio_project_contract.dart';
import '../../features/session/models/audio_session.dart';

AudioProjectStore createAudioProjectStore({String? directoryPath}) =>
    const UnavailableAudioProjectStore();

class UnavailableAudioProjectStore implements AudioProjectStore {
  const UnavailableAudioProjectStore();

  @override
  String get directoryPath => '';

  @override
  Future<String> save(AudioSession session) async {
    throw const AudioProjectStoreUnavailable(
      'Local project storage is not available on this platform.',
    );
  }

  @override
  Future<String> savePortable(AudioSession session) async {
    throw const AudioProjectStoreUnavailable(
      'Portable local project storage is not available on this platform.',
    );
  }

  @override
  Future<bool> mediaExists(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local media checks are not available on this platform.',
    );
  }

  @override
  Future<AudioProjectIntegrityReport> verifyPortableProject(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Portable project verification is not available on this platform.',
    );
  }

  @override
  Future<String> exportPortableArchive(String projectPath, String zipPath) async {
    throw const AudioProjectStoreUnavailable(
      'ZIP project export is not available on this platform.',
    );
  }

  @override
  Future<String> importPortableArchive(String zipPath) async {
    throw const AudioProjectStoreUnavailable(
      'ZIP project import is not available on this platform.',
    );
  }

  @override
  Future<AudioSession> load(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local project storage is not available on this platform.',
    );
  }

  @override
  Future<List<AudioProjectSummary>> listProjects() async {
    throw const AudioProjectStoreUnavailable(
      'Local project storage is not available on this platform.',
    );
  }

  @override
  Future<List<AudioProjectSummary>> findProjectsUsingMedia(String mediaPath) async {
    throw const AudioProjectStoreUnavailable(
      'Local project reference checks are not available on this platform.',
    );
  }

  @override
  Future<String> saveRecoverySnapshot(AudioSession session) async {
    throw const AudioProjectStoreUnavailable(
      'Local project recovery is not available on this platform.',
    );
  }

  @override
  Future<AudioSession> loadRecoverySnapshot(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local project recovery is not available on this platform.',
    );
  }

  @override
  Future<List<AudioProjectSummary>> listRecoverySnapshots() async {
    throw const AudioProjectStoreUnavailable(
      'Local project recovery is not available on this platform.',
    );
  }

  @override
  Future<void> deleteRecoverySnapshot(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local project recovery is not available on this platform.',
    );
  }

  @override
  Future<void> delete(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local project storage is not available on this platform.',
    );
  }
}
