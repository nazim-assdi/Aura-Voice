import 'audio_library_stub.dart'
    if (dart.library.io) 'audio_library_io.dart' as platform;

import 'audio_library_contract.dart';

export 'audio_library_contract.dart';

AudioLibraryService createAudioLibraryService({String? directoryPath}) =>
    platform.createAudioLibraryService(directoryPath: directoryPath);
