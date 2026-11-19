import 'dart:typed_data';

import 'audio_recording_contract.dart';

Future<Uint8List> readAudioFile(String path) async {
  throw const AudioRecordingUnavailable(
    'Reading local audio files is not supported on this platform.',
  );
}
