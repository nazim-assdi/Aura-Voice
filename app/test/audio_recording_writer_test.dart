import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_recording_io.dart';

void main() {
  group('FileAudioRecordingWriter', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp('aura-voice-test-');
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('writes a finalized 24-bit mono PCM WAV', () async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: 48000, channels: 1);
      await writer.append(Float32List.fromList([-1.0, 0.0, 0.5, 1.0]));
      final path = await writer.finish();

      final bytes = await File(path).readAsBytes();
      final header = ByteData.sublistView(bytes);
      expect(bytes.length, 44 + 4 * 3);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(24, Endian.little), 48000);
      expect(header.getUint16(34, Endian.little), 24);
      expect(header.getUint32(40, Endian.little), 12);
      expect(bytes.sublist(44, 47), [0, 0, 128]);
      expect(bytes.sublist(50, 53), [0, 0, 64]);
      expect(writer.isOpen, isFalse);
      expect(writer.filePath, path);
    });

    test('writes interleaved stereo without changing sample order', () async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: 44100, channels: 2);
      await writer.append(Float32List.fromList([0.25, -0.25, 0.5, -0.5]));
      final path = await writer.finish();
      final bytes = await File(path).readAsBytes();

      expect(ByteData.sublistView(bytes).getUint16(22, Endian.little), 2);
      expect(ByteData.sublistView(bytes).getUint32(40, Endian.little), 12);
      expect(bytes.length, 56);
    });

    test('discard closes and deletes the partial recording', () async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: 48000, channels: 1);
      await writer.append(Float32List.fromList([0.2, 0.3]));
      final path = writer.filePath!;

      await writer.discard();

      expect(await File(path).exists(), isFalse);
      expect(writer.isOpen, isFalse);
      expect(writer.filePath, isNull);
    });

    test('rejects partial interleaved frames', () async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: 48000, channels: 2);
      await expectLater(
        writer.append(Float32List.fromList([0.1])),
        throwsArgumentError,
      );
      await writer.discard();
    });
  });
}
