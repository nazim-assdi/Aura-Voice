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
      expect(recordings.single.frameCount, 4800);
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

    test('imports a valid external WAV into the managed library', () async {
      final externalDirectory = await Directory.systemTemp.createTemp(
        'aura-external-wav-',
      );
      try {
        final externalWriter = FileAudioRecordingWriter(
          directoryPath: externalDirectory.path,
        );
        await externalWriter.start(sampleRate: 44100, channels: 2);
        await externalWriter.append(Float32List(4410)..fillRange(0, 4410, 0.2));
        final sourcePath = await externalWriter.finish();
        final sourceBytes = await File(sourcePath).readAsBytes();

        final imported = await library.importRecording(sourcePath);

        expect(imported.name, startsWith('AuraVoice_'));
        expect(imported.path, isNot(sourcePath));
        expect(imported.path, startsWith(temporaryDirectory.path));
        expect(imported.sampleRate, 44100);
        expect(imported.channels, 2);
        expect(imported.bitsPerSample, 24);
        expect(await File(imported.path).readAsBytes(), sourceBytes);
        expect(await library.listRecordings(), hasLength(1));
      } finally {
        await externalDirectory.delete(recursive: true);
      }
    });

    test('imports duplicate WAV names without overwriting an existing take', () async {
      final externalDirectory = await Directory.systemTemp.createTemp(
        'aura-duplicate-wav-',
      );
      try {
        final writer = FileAudioRecordingWriter(
          directoryPath: externalDirectory.path,
        );
        await writer.start(sampleRate: 48000, channels: 1);
        await writer.append(Float32List(480)..fillRange(0, 480, 0.1));
        final sourcePath = await writer.finish();
        final first = await library.importRecording(sourcePath);
        final second = await library.importRecording(sourcePath);

        expect(first.name, second.name);
        expect(first.path, isNot(second.path));
        expect((await library.listRecordings()), hasLength(2));
      } finally {
        await externalDirectory.delete(recursive: true);
      }
    });

    test('rejects invalid external files and does not leave partial copies', () async {
      final invalid = File(
        '${temporaryDirectory.parent.path}${Platform.pathSeparator}'
        'invalid-import-${temporaryDirectory.path.split(Platform.pathSeparator).last}.wav',
      );
      await invalid.writeAsBytes([1, 2, 3, 4, 5]);
      try {
        await expectLater(
          library.importRecording(invalid.path),
          throwsA(isA<AudioLibraryUnavailable>()),
        );
        expect(await library.listRecordings(), isEmpty);
      } finally {
        await invalid.delete();
      }
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

    test('keeps the same file when the requested name is unchanged', () async {
      final path = await createTake();
      final recording = (await library.listRecordings()).single;

      final renamed = await library.renameRecording(recording, recording.name);

      expect(renamed.path, path);
      expect(await File(path).exists(), isTrue);
      expect(await library.listRecordings(), hasLength(1));
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
        frameCount: 0,
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

    test('refuses to mutate a library symlink that points outside the folder', () async {
      if (Platform.isWindows) return;
      final folderToken = temporaryDirectory.path
          .split(Platform.pathSeparator)
          .last;
      final outside = File(
        '${temporaryDirectory.parent.path}${Platform.pathSeparator}linked-outside-$folderToken.wav',
      );
      await outside.writeAsBytes([1, 2, 3, 4]);
      final link = Link(
        '${temporaryDirectory.path}${Platform.pathSeparator}linked.wav',
      );
      await link.create(outside.path);
      final recording = AudioLibraryRecording(
        path: link.path,
        name: 'linked',
        modifiedAt: DateTime.now(),
        sizeBytes: 4,
        duration: Duration.zero,
        frameCount: 0,
        sampleRate: 48000,
        channels: 1,
        bitsPerSample: 24,
      );

      await expectLater(
        library.deleteRecording(recording),
        throwsA(isA<AudioLibraryUnavailable>()),
      );
      expect(await outside.exists(), isTrue);
      expect(await link.exists(), isTrue);
      await link.delete();
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
