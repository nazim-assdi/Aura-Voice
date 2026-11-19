import 'audio_project_stub.dart'
    if (dart.library.io) 'audio_project_io.dart' as platform;

import 'audio_project_contract.dart';

export 'audio_project_contract.dart';

AudioProjectStore createAudioProjectStore({String? directoryPath}) =>
    platform.createAudioProjectStore(directoryPath: directoryPath);
