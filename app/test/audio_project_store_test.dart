import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_project_contract.dart';
import 'package:aura_voice_ai/core/services/audio_project_io.dart';
import 'package:aura_voice_ai/features/session/models/audio_session.dart';

void main() {
  group('FileAudioProjectStore', () {
    late Directory temporaryDirectory;
    late FileAudioProjectStore store;

    setUp(() async {
      temporaryDirectory =
          await Directory.systemTemp.createTemp('aura-project-test-');
      store = FileAudioProjectStore(directoryPath: temporaryDirectory.path);
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    AudioSession makeSession() => AudioSession(
          id: 'project-test-1',
          title: 'Voice Over Test',
          sampleRate: 48000,
          channels: 2,
          bitDepth: 24,
          tracks: [
            AudioTrack(
              id: 'voice-1',
              name: 'Lead Voice',
              muted: false,
              clips: [
                AudioClip(
                  id: 'clip-1',
                  mediaId: '/local/recordings/take.wav',
                  startFrame: 12000,
                  sourceStartFrame: 240,
                  durationFrames: 48000,
                  gain: 0.75,
                  pan: -0.2,
                  fadeInFrames: 1200,
                  fadeOutFrames: 2400,
                ),
              ],
            ),
            AudioTrack(
              id: 'voice-2',
              name: 'Second Voice',
              kind: AudioTrackKind.effects,
            ),
          ],
          markers: [
            AudioMarker(id: 'marker-1', label: 'Intro', frame: 12000),
          ],
        );

    test('saves and reloads a sample-frame session manifest', () async {
      final source = makeSession();

      final path = await store.save(source);
      final loaded = await store.load(path);

      expect(path, endsWith('AuraProject_project-test-1.aura.json'));
      expect(loaded.id, source.id);
      expect(loaded.title, source.title);
      expect(loaded.sampleRate, 48000);
      expect(loaded.tracks, hasLength(2));
      expect(loaded.tracks.first.clips.single.startFrame, 12000);
      expect(loaded.tracks.first.clips.single.sourceStartFrame, 240);
      expect(loaded.tracks.first.clips.single.durationFrames, 48000);
      expect(loaded.tracks.first.clips.single.fadeInFrames, 1200);
      expect(loaded.markers.single.label, 'Intro');
    });

    test('lists saved projects with title, format and track count', () async {
      await store.save(makeSession());

      final projects = await store.listProjects();

      expect(projects, hasLength(1));
      expect(projects.single.title, 'Voice Over Test');
      expect(projects.single.sampleRate, 48000);
      expect(projects.single.trackCount, 2);
    });

    test('updates the existing manifest when saving the same project id', () async {
      final original = makeSession();
      final firstPath = await store.save(original);
      final updated = AudioSession(
        id: original.id,
        title: 'Updated title',
        sampleRate: original.sampleRate,
        channels: original.channels,
        bitDepth: original.bitDepth,
        tracks: original.tracks,
      );

      final secondPath = await store.save(updated);
      final loaded = await store.load(secondPath);

      expect(secondPath, firstPath);
      expect(loaded.title, 'Updated title');
      expect(await store.listProjects(), hasLength(1));
    });

    test('finds saved sessions that reference a source WAV', () async {
      await store.save(makeSession());

      final references =
          await store.findProjectsUsingMedia('/local/recordings/take.wav');

      expect(references, hasLength(1));
      expect(references.single.title, 'Voice Over Test');
    });

    test('returns no references for unrelated media paths', () async {
      await store.save(makeSession());

      expect(
        await store.findProjectsUsingMedia('/local/recordings/other.wav'),
        isEmpty,
      );
    });

    test('deletes a project manifest from the managed folder', () async {
      final path = await store.save(makeSession());

      await store.delete(path);

      expect(await store.listProjects(), isEmpty);
    });

    test('refuses to load or delete files outside the Projects folder', () async {
      final outside = File(
        '${temporaryDirectory.parent.path}${Platform.pathSeparator}outside-${temporaryDirectory.path.split(Platform.pathSeparator).last}.aura.json',
      );
      await outside.writeAsString('{}');

      await expectLater(
        store.load(outside.path),
        throwsA(isA<AudioProjectStoreUnavailable>()),
      );
      await expectLater(
        store.delete(outside.path),
        throwsA(isA<AudioProjectStoreUnavailable>()),
      );
      expect(await outside.exists(), isTrue);
      await outside.delete();
    });

    test('restores a backup when the main manifest is missing', () async {
      final path = await store.save(makeSession());
      final backup = File('$path.backup');
      await File(path).rename(backup.path);

      final projects = await store.listProjects();

      expect(projects, hasLength(1));
      expect(await File(path).exists(), isTrue);
      expect(await backup.exists(), isFalse);
      expect((await store.load(path)).title, 'Voice Over Test');
    });

    test('removes stale backup when the main manifest exists', () async {
      final path = await store.save(makeSession());
      final backup = File('$path.backup');
      await backup.writeAsString('stale backup');

      await store.listProjects();

      expect(await File(path).exists(), isTrue);
      expect(await backup.exists(), isFalse);
    });

    test('ignores damaged project manifests while listing', () async {
      await store.save(makeSession());
      await File(
        '${temporaryDirectory.path}${Platform.pathSeparator}broken.aura.json',
      ).writeAsString('{not-json');

      expect(await store.listProjects(), hasLength(1));
    });
  });
}
