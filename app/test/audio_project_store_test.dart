import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_project_contract.dart';
import 'package:aura_voice_ai/core/services/audio_project_io.dart';
import 'package:aura_voice_ai/features/session/models/audio_session.dart';

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.path.split(Platform.pathSeparator).last;
    final target = '${destination.path}${Platform.pathSeparator}$name';
    if (entity is File) {
      await entity.copy(target);
    } else if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    }
  }
}

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

    test('stores and reloads the latest recovery snapshot for a session', () async {
      final original = makeSession();
      final firstPath = await store.saveRecoverySnapshot(original);
      final updated = AudioSession(
        id: original.id,
        title: 'Recovered Voice Over',
        sampleRate: original.sampleRate,
        channels: original.channels,
        bitDepth: original.bitDepth,
        tracks: original.tracks,
        markers: original.markers,
      );

      final secondPath = await store.saveRecoverySnapshot(updated);
      final recoveries = await store.listRecoverySnapshots();
      final loaded = await store.loadRecoverySnapshot(secondPath);

      expect(secondPath, firstPath);
      expect(recoveries, hasLength(1));
      expect(recoveries.single.title, 'Recovered Voice Over');
      expect(loaded.title, 'Recovered Voice Over');
      expect(await store.listProjects(), isEmpty);
    });

    test('restores an interrupted recovery snapshot from its backup file', () async {
      final path = await store.saveRecoverySnapshot(makeSession());
      final backup = File('$path.backup');
      await File(path).rename(backup.path);

      final snapshots = await store.listRecoverySnapshots();

      expect(snapshots, hasLength(1));
      expect(await File(path).exists(), isTrue);
      expect(await backup.exists(), isFalse);
      expect((await store.loadRecoverySnapshot(path)).title, 'Voice Over Test');
    });

    test('promotes a recovered session to a project and clears the recovery copy', () async {
      final original = makeSession();
      final recoveryPath = await store.saveRecoverySnapshot(original);

      final recovered = await store.loadRecoverySnapshot(recoveryPath);
      final projectPath = await store.save(recovered);

      final loadedProject = await store.load(projectPath);
      expect(loadedProject.title, original.title);
      expect(loadedProject.tracks, hasLength(original.tracks.length));
      expect(await store.listRecoverySnapshots(), isEmpty);
      expect(await store.listProjects(), hasLength(1));
    });

    test('does not load a regular project manifest as a recovery snapshot', () async {
      final projectPath = await store.save(makeSession());

      await expectLater(
        store.loadRecoverySnapshot(projectPath),
        throwsA(isA<AudioProjectStoreUnavailable>()),
      );
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

    test('packages source media and resolves it from a moved project folder', () async {
      final source = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}portable-source.wav',
      );
      final sourceBytes = List<int>.generate(256, (index) => index % 255);
      await source.writeAsBytes(sourceBytes);
      final session = AudioSession(
        id: 'portable-project',
        title: 'Portable Voice Session',
        sampleRate: 48000,
        channels: 2,
        bitDepth: 24,
        tracks: [
          AudioTrack(
            id: 'portable-track',
            name: 'Voice',
            clips: [
              AudioClip(
                id: 'portable-clip',
                mediaId: source.path,
                startFrame: 0,
                sourceStartFrame: 0,
                durationFrames: 100,
              ),
            ],
          ),
        ],
      );

      final manifestPath = await store.savePortable(session);
      final loaded = await store.load(manifestPath);
      final packagedPath = loaded.tracks.single.clips.single.mediaId;
      expect(packagedPath, isNot(source.path));
      expect(await File(packagedPath).readAsBytes(), sourceBytes);
      expect(await File(manifestPath).readAsString(), contains('.assets-'));

      final assetFolderName =
          File(packagedPath).parent.path.split(Platform.pathSeparator).last;
      final movedDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}moved-project',
      );
      await movedDirectory.create(recursive: true);
      final manifestName = File(manifestPath).uri.pathSegments.last;
      final movedManifest = await File(manifestPath).copy(
        '${movedDirectory.path}${Platform.pathSeparator}$manifestName',
      );
      final sourceAssets = Directory(
        '${store.directoryPath}${Platform.pathSeparator}$assetFolderName',
      );
      final movedAssets = Directory(
        '${movedDirectory.path}${Platform.pathSeparator}$assetFolderName',
      );
      await _copyDirectory(sourceAssets, movedAssets);

      final movedStore = FileAudioProjectStore(
        directoryPath: movedDirectory.path,
      );
      final movedSession = await movedStore.load(movedManifest.path);
      final movedMediaPath = movedSession.tracks.single.clips.single.mediaId;
      expect(movedMediaPath, startsWith(movedDirectory.path));
      expect(await File(movedMediaPath).readAsBytes(), sourceBytes);
    });

    test('verifies packaged media with SHA-256 and reports corrupted assets', () async {
      final source = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}checksum-source.wav',
      );
      await source.writeAsBytes(List<int>.generate(512, (index) => index % 251));
      final session = AudioSession(
        id: 'checksum-project',
        title: 'Checksum Project',
        sampleRate: 48000,
        channels: 1,
        bitDepth: 24,
        tracks: [
          AudioTrack(
            id: 'checksum-track',
            name: 'Voice',
            clips: [
              AudioClip(
                id: 'checksum-clip',
                mediaId: source.path,
                startFrame: 0,
                sourceStartFrame: 0,
                durationFrames: 128,
              ),
            ],
          ),
        ],
      );

      final manifestPath = await store.savePortable(session);
      final valid = await store.verifyPortableProject(manifestPath);
      expect(valid.isValid, isTrue);
      expect(valid.hasChecksumManifest, isTrue);
      expect(valid.checkedAssetCount, 1);

      final loaded = await store.load(manifestPath);
      final packagedPath = loaded.tracks.single.clips.single.mediaId;
      await File(packagedPath).writeAsBytes(
        List<int>.filled(512, 7),
        flush: true,
      );
      final damaged = await store.verifyPortableProject(manifestPath);
      expect(damaged.isValid, isFalse);
      expect(damaged.corruptMediaPaths, hasLength(1));
    });

    test('exports and imports a verified portable ZIP project', () async {
      final source = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}zip-source.wav',
      );
      final sourceBytes = List<int>.generate(2048, (index) => (index * 13) % 255);
      await source.writeAsBytes(sourceBytes);
      final session = AudioSession(
        id: 'zip-round-trip',
        title: 'ZIP Round Trip',
        sampleRate: 48000,
        channels: 2,
        bitDepth: 24,
        tracks: [
          AudioTrack(
            id: 'zip-track',
            name: 'Voice',
            clips: [
              AudioClip(
                id: 'zip-clip',
                mediaId: source.path,
                startFrame: 0,
                sourceStartFrame: 0,
                durationFrames: 512,
              ),
            ],
          ),
        ],
      );

      final manifestPath = await store.savePortable(session);
      final zipPath =
          '${temporaryDirectory.path}${Platform.pathSeparator}zip-round-trip.auravoice.zip';
      final exported = await store.exportPortableArchive(manifestPath, zipPath);
      expect(exported, zipPath);
      expect(await File(zipPath).exists(), isTrue);

      final importedDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}imported-projects',
      );
      final importer = FileAudioProjectStore(
        directoryPath: importedDirectory.path,
      );
      final importedManifest = await importer.importPortableArchive(zipPath);
      final report = await importer.verifyPortableProject(importedManifest);
      final importedSession = await importer.load(importedManifest);
      final importedMedia =
          importedSession.tracks.single.clips.single.mediaId;

      expect(report.isValid, isTrue);
      expect(report.hasChecksumManifest, isTrue);
      expect(report.checkedAssetCount, 1);
      expect(importedSession.title, session.title);
      expect(await File(importedMedia).readAsBytes(), sourceBytes);
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

    test('refuses to load a project symlink that points outside the Projects folder', () async {
      if (Platform.isWindows) return;
      final folderToken = temporaryDirectory.path
          .split(Platform.pathSeparator)
          .last;
      final outside = File(
        '${temporaryDirectory.parent.path}${Platform.pathSeparator}linked-outside-$folderToken.aura.json',
      );
      await outside.writeAsString('{}');
      final link = Link(
        '${temporaryDirectory.path}${Platform.pathSeparator}linked.aura.json',
      );
      await link.create(outside.path);

      await expectLater(
        store.load(link.path),
        throwsA(isA<AudioProjectStoreUnavailable>()),
      );
      expect(await outside.exists(), isTrue);
      await link.delete();
      await outside.delete();
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
