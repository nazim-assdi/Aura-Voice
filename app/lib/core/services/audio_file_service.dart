import 'audio_file_stub.dart'
    if (dart.library.io) 'audio_file_io.dart' as platform;

import 'dart:typed_data';

Future<Uint8List> readAudioFile(String path) => platform.readAudioFile(path);
