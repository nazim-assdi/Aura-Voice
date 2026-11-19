import 'dart:typed_data';

import 'audio_recording_contract.dart';

AudioRecordingWriter createAudioRecordingWriter({String? directoryPath}) =>
    const UnavailableAudioRecordingWriter();

class UnavailableAudioRecordingWriter implements AudioRecordingWriter {
  const UnavailableAudioRecordingWriter();

  @override
  bool get isOpen => false;

  @override
  String? get filePath => null;

  @override
  Future<void> start({
    required int sampleRate,
    required int channels,
    String? directoryPath,
  }) async {
    throw const AudioRecordingUnavailable(
      'Local WAV recording is not available on this platform.',
    );
  }

  @override
  Future<void> append(Float32List interleavedSamples) async {
    throw const AudioRecordingUnavailable(
      'Local WAV recording is not available on this platform.',
    );
  }

  @override
  Future<String> finish() async {
    throw const AudioRecordingUnavailable(
      'No recording file is open.',
    );
  }

  @override
  Future<void> discard() async {}
}
