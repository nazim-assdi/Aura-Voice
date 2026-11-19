import 'audio_recording_stub.dart'
    if (dart.library.io) 'audio_recording_io.dart' as platform;

import 'audio_recording_contract.dart';

export 'audio_recording_contract.dart';

AudioRecordingWriter createAudioRecordingWriter({String? directoryPath}) =>
    platform.createAudioRecordingWriter(directoryPath: directoryPath);
