import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_library_contract.dart';
import 'package:aura_voice_ai/core/services/audio_library_io.dart';
import 'package:aura_voice_ai/core/services/audio_recording_io.dart';

void main() {
  group('FileAudioLibraryService', () {
    late Directory temporaryDirectory;
    late FileAudioLibraryService library;

    setUp(() async {
      temporaryDirectory =
          await Directory.systemTemp.createTemp('aura-library-test-');
      library = FileAudioLibraryService(
        directoryPath: temporaryDirectory.path,
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    Future<String> createTake({
      int sampleRate = 48000,
      int channels = 1,
      int frames = 4800,
    }) async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: sampleRate, channels: channels);
      await writer.append(
        Float32List(frames * channels)..fillRange(0, frames * channels, 0.1),
      );
      return writer.finish();
    }

    test('lists WAV metadata without loading the audio payload', () async {
      await createTake();

      final recordings = await library.listRecordings();

      expect(recordings, hasLength(1));
      expect(recordings.single.sampleRate, 48000);
      expect(recordings.single.channels, 1);
      expect(recordings.single.bitsPerSample, 24);
      expect(recordings.single.duration, const Duration(milliseconds: 100));
      expect(recordings.single.sizeBytes, 44 + 4800 * 3);
      expect(recordings.single.name, startsWith('AuraVoice_'));
    });

    test('reads stereo metadata and sorts newest first', () async {
      await createTake(sampleRate: 44100, channels: 2, frames: 2205);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await createTake();

      final recordings = await library.listRecordings();

      expect(recordings, hasLength(2));
      expect(recordings.first.channels, 1);
      expect(recordings.last.channels, 2);
      expect(recordings.last.sampleRate, 44100);
      expect(recordings.last.duration, const Duration(milliseconds: 50));
    });

    test('renames a take and preserves its WAV metadata', () async {
      final originalPath = await createTake();
      final original = (await library.listRecordings()).single;

      final renamed = await library.renameRecording(original, 'Client interview');

      expect(renamed.name, 'Client interview');
      expect(renamed.path, isNot(originalPath));
      expect(renamed.path, endsWith('Client interview.wav'));
      expect(renamed.sampleRate, 48000);
      expect(await File(originalPath).exists(), isFalse);
      expect((await library.listRecordings()).single.name, 'Client interview');
    });

    test('resolves duplicate names without overwriting another take', () async {
      final firstPath = await createTake();
      await createTake();
      final recordings = await library.listRecordings();

      final firstRenamed = await library.renameRecording(
        recordings.firstWhere((item) => item.path == firstPath),
        'Shared title',
      );
      final secondRenamed = await library.renameRecording(
        recordings.firstWhere((item) => item.path != firstPath),
        'Shared title',
      );

      expect(firstRenamed.name, 'Shared title');
      expect(secondRenamed.name, 'Shared title (2)');
      expect((await library.listRecordings()), hasLength(2));
    });

    test('deletes a take from the managed library folder', () async {
      await createTake();
      final recording = (await library.listRecordings()).single;

      await library.deleteRecording(recording);

      expect(await library.listRecordings(), isEmpty);
    });

    test('refuses to delete a WAV outside the managed directory', () async {
      final folderToken = temporaryDirectory.path
          .split(Platform.pathSeparator)
          .last;
      final outside = File(
        '${temporaryDirectory.parent.path}${Platform.pathSeparator}outside-$folderToken.wav',
      );
      await outside.writeAsBytes([1, 2, 3]);
      final recording = AudioLibraryRecording(
        path: outside.path,
        name: 'outside',
        modifiedAt: DateTime.now(),
        sizeBytes: 3,
        duration: Duration.zero,
        sampleRate: 48000,
        channels: 1,
        bitsPerSample: 24,
      );

      await expectLater(
        library.deleteRecording(recording),
        throwsA(isA<AudioLibraryUnavailable>()),
      );
      expect(await outside.exists(), isTrue);
      await outside.delete();
    });

    test('ignores invalid WAV files instead of breaking the library', () async {
      await File(
        '${temporaryDirectory.path}${Platform.pathSeparator}broken.wav',
      ).writeAsBytes([1, 2, 3, 4, 5]);

      expect(await library.listRecordings(), isEmpty);
    });

    test('creates the folder lazily and lists an empty library', () async {
      final nested = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}new-library',
      );
      final emptyLibrary = FileAudioLibraryService(
        directoryPath: nested.path,
      );

      expect(await emptyLibrary.listRecordings(), isEmpty);
      expect(await nested.exists(), isFalse);
    });
  });
}
