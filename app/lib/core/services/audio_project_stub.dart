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
  Future<void> delete(String path) async {
    throw const AudioProjectStoreUnavailable(
      'Local project storage is not available on this platform.',
    );
  }
}
