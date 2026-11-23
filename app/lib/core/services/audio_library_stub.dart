import 'audio_library_contract.dart';

AudioLibraryService createAudioLibraryService({String? directoryPath}) =>
    const UnavailableAudioLibraryService();

class UnavailableAudioLibraryService implements AudioLibraryService {
  const UnavailableAudioLibraryService();

  @override
  String get directoryPath => '';

  @override
  Future<List<AudioLibraryRecording>> listRecordings() async {
    throw const AudioLibraryUnavailable(
      'The local recording library is not available on this platform.',
    );
  }

  @override
  Future<AudioLibraryRecording> importRecording(String sourcePath) async {
    throw const AudioLibraryUnavailable(
      'Importing local WAV files is not available on this platform.',
    );
  }

  @override
  Future<AudioLibraryRecording> renameRecording(
    AudioLibraryRecording recording,
    String newName,
  ) async {
    throw const AudioLibraryUnavailable(
      'Renaming local recordings is not available on this platform.',
    );
  }

  @override
  Future<void> deleteRecording(AudioLibraryRecording recording) async {
    throw const AudioLibraryUnavailable(
      'Deleting local recordings is not available on this platform.',
    );
  }
}
