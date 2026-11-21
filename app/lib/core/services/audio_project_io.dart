import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../features/session/models/audio_session.dart';
import 'audio_project_contract.dart';

AudioProjectStore createAudioProjectStore({String? directoryPath}) =>
    FileAudioProjectStore(directoryPath: directoryPath);

/// Stores versioned session manifests. Source WAV files are not copied or
/// modified; clips refer to their original local media paths.
class FileAudioProjectStore implements AudioProjectStore {
  FileAudioProjectStore({String? directoryPath})
      : _directoryPath = directoryPath ?? _defaultDirectoryPath();

  final String _directoryPath;

  @override
  String get directoryPath => _directoryPath;

  @override
  Future<String> save(AudioSession session) async {
    final directory = Directory(_directoryPath);
    await directory.create(recursive: true);
    final filename = 'AuraProject_${_safeId(session.id)}.aura.json';
    final file = File(
      '${directory.path}${Platform.pathSeparator}$filename',
    );
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final backup = File('${file.path}.backup');
    final manifest = jsonEncode(session.toJson());
    final random = await temporary.open(mode: FileMode.write);
    try {
      await random.writeString(manifest);
      await random.flush();
    } finally {
      await random.close();
    }

    var movedOldFile = false;
    try {
      if (await file.exists()) {
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
        movedOldFile = true;
      }
      await temporary.rename(file.path);
      if (movedOldFile && await backup.exists()) {
        await backup.delete();
      }
      await _deleteRecoverySnapshotForId(session.id);
      return file.path;
    } catch (_) {
      if (movedOldFile && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<String> savePortable(AudioSession session) async {
    final rootDirectory = Directory(_directoryPath);
    await rootDirectory.create(recursive: true);
    final root = await rootDirectory.resolveSymbolicLinks();
    final assetFolderName =
        'AuraProject_${_safeId(session.id)}.assets-${DateTime.now().microsecondsSinceEpoch}';
    final stagingDirectory = Directory(
      '$root${Platform.pathSeparator}$assetFolderName.tmp',
    );
    final publishedDirectory = Directory(
      '$root${Platform.pathSeparator}$assetFolderName',
    );
    await stagingDirectory.create(recursive: true);

    final relativeByCanonicalPath = <String, String>{};
    final mediaReferences = <String, String>{};
    final assetChecksums = <String, Map<String, Object>>{};
    var manifestSaved = false;
    try {
      for (final track in session.tracks) {
        for (final clip in track.clips) {
          if (mediaReferences.containsKey(clip.mediaId)) continue;
          final source = File(clip.mediaId);
          if (await FileSystemEntity.type(source.path, followLinks: true) !=
              FileSystemEntityType.file) {
            throw AudioProjectStoreUnavailable(
              'Cannot package missing media "${clip.mediaId}". Relink this WAV file and save the project again.',
            );
          }
          final canonicalPath = await source.resolveSymbolicLinks();
          final canonicalKey =
              Platform.isWindows ? canonicalPath.toLowerCase() : canonicalPath;
          var relativeName = relativeByCanonicalPath[canonicalKey];
          if (relativeName == null) {
            final sourceName = clip.mediaId.split(RegExp(r'[\\/]')).last;
            var safeName =
                sourceName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
            if (safeName.isEmpty) safeName = 'audio.wav';
            if (safeName.length > 100) {
              safeName = safeName.substring(safeName.length - 100);
            }
            relativeName = '${_stableHash(canonicalPath)}_$safeName';
            final sourceStat = await source.stat();
            final copied = await source.copy(
              '${stagingDirectory.path}${Platform.pathSeparator}$relativeName',
            );
            if (await copied.length() != sourceStat.size) {
              throw AudioProjectStoreUnavailable(
                'The media copy did not complete successfully for "${clip.mediaId}".',
              );
            }
            final digest = await sha256.bind(copied.openRead()).first;
            assetChecksums[relativeName] = {
              'sizeBytes': sourceStat.size,
              'sha256': digest.toString(),
            };
            relativeByCanonicalPath[canonicalKey] = relativeName;
          }
          mediaReferences[clip.mediaId] = '$assetFolderName/$relativeName';
        }
      }

      final assetManifest = File(
        '${stagingDirectory.path}${Platform.pathSeparator}.aura-assets.json',
      );
      await assetManifest.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'projectId': session.id,
          'assetFolder': assetFolderName,
          'files': assetChecksums,
        }),
        flush: true,
      );

      final portableTracks = session.tracks.map((track) {
        return AudioTrack(
          id: track.id,
          name: track.name,
          kind: track.kind,
          gain: track.gain,
          pan: track.pan,
          muted: track.muted,
          solo: track.solo,
          armed: track.armed,
          highPassHz: track.highPassHz,
          compressorThreshold: track.compressorThreshold,
          compressorRatio: track.compressorRatio,
          clips: track.clips.map((clip) {
            return AudioClip(
              id: clip.id,
              mediaId: mediaReferences[clip.mediaId]!,
              startFrame: clip.startFrame,
              sourceStartFrame: clip.sourceStartFrame,
              durationFrames: clip.durationFrames,
              gain: clip.gain,
              pan: clip.pan,
              muted: clip.muted,
              fadeInFrames: clip.fadeInFrames,
              fadeOutFrames: clip.fadeOutFrames,
            );
          }).toList(),
        );
      }).toList();
      final portableSession = AudioSession(
        id: session.id,
        title: session.title,
        sampleRate: session.sampleRate,
        channels: session.channels,
        bitDepth: session.bitDepth,
        tracks: portableTracks,
        markers: session.markers,
      );

      await stagingDirectory.rename(publishedDirectory.path);
      final manifestPath = await save(portableSession);
      manifestSaved = true;
      try {
        await _removeSupersededAssetFolders(
          root,
          'AuraProject_${_safeId(session.id)}.assets-',
          assetFolderName,
        );
      } catch (_) {
        // The manifest and its new assets are already committed. Old asset
        // folders are harmless and can be cleaned up on a later save.
      }
      return manifestPath;
    } catch (_) {
      if (!manifestSaved) {
        if (await stagingDirectory.exists()) {
          await stagingDirectory.delete(recursive: true);
        }
        if (await publishedDirectory.exists()) {
          await publishedDirectory.delete(recursive: true);
        }
      }
      rethrow;
    }
  }

  @override
  Future<bool> mediaExists(String path) async =>
      await FileSystemEntity.type(path, followLinks: true) ==
      FileSystemEntityType.file;

  @override
  Future<AudioProjectIntegrityReport> verifyPortableProject(
    String path,
  ) async {
    await _assertManagedPath(path);
    final manifestFile = File(path);
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Aura Voice project manifest.');
    }
    final session = AudioSession.fromJson(decoded);
    final references = session.tracks
        .expand((track) => track.clips)
        .map((clip) => clip.mediaId)
        .toSet();
    final missing = <String>{};
    final corrupt = <String>{};
    final referencesByRelativeName = <String, String>{};
    String? assetFolder;
    var hasChecksumManifest = false;
    Map<String, dynamic>? checksumFiles;

    for (final reference in references) {
      if (_isAbsoluteMediaPath(reference)) {
        if (!await mediaExists(reference)) missing.add(reference);
        continue;
      }
      final segments = reference.replaceAll('\\', '/').split('/');
      if (segments.length != 2 ||
          segments.any((segment) =>
              segment.isEmpty || segment == '.' || segment == '..') ||
          !segments.first.startsWith('AuraProject_') ||
          !segments.first.contains('.assets-')) {
        corrupt.add(reference);
        continue;
      }
      if (assetFolder != null && assetFolder != segments.first) {
        corrupt.add(reference);
        continue;
      }
      assetFolder = segments.first;
      referencesByRelativeName[segments.last] = reference;
      final resolved = await _resolvePortableMediaPath(
        reference,
        manifestFile.parent.path,
      );
      if (!await mediaExists(resolved)) {
        missing.add(reference);
      }
    }

    if (assetFolder != null) {
      final metadataFile = File(
        '${manifestFile.parent.path}${Platform.pathSeparator}$assetFolder'
        '${Platform.pathSeparator}.aura-assets.json',
      );
      if (await metadataFile.exists()) {
        try {
          final metadata = jsonDecode(await metadataFile.readAsString());
          if (metadata is! Map<String, dynamic> ||
              metadata['schemaVersion'] != 1 ||
              metadata['assetFolder'] != assetFolder ||
              metadata['files'] is! Map<String, dynamic>) {
            throw const FormatException('Invalid portable asset inventory.');
          }
          checksumFiles = metadata['files'] as Map<String, dynamic>;
          hasChecksumManifest = true;
        } catch (_) {
          corrupt.addAll(references);
        }
      }
    }

    var checkedAssetCount = 0;
    if (hasChecksumManifest && checksumFiles != null) {
      for (final entry in referencesByRelativeName.entries) {
        final expected = checksumFiles[entry.key];
        if (expected is! Map<String, dynamic>) {
          corrupt.add(entry.value);
          continue;
        }
        final expectedSize = expected['sizeBytes'];
        final expectedHash = expected['sha256'];
        final resolvedPath = await _resolvePortableMediaPath(
          entry.value,
          manifestFile.parent.path,
        );
        if (!await File(resolvedPath).exists()) continue;
        try {
          final file = File(resolvedPath);
          final stat = await file.stat();
          if (expectedSize is! int ||
              expectedHash is! String ||
              stat.size != expectedSize) {
            corrupt.add(entry.value);
            continue;
          }
          final actualHash = await sha256.bind(file.openRead()).first;
          checkedAssetCount++;
          if (actualHash.toString().toLowerCase() !=
              expectedHash.toLowerCase()) {
            corrupt.add(entry.value);
          }
        } catch (_) {
          corrupt.add(entry.value);
        }
      }
    }

    return AudioProjectIntegrityReport(
      checkedAssetCount: checkedAssetCount,
      missingMediaPaths: missing.toList()..sort(),
      corruptMediaPaths: corrupt.toList()..sort(),
      hasChecksumManifest: hasChecksumManifest,
    );
  }

  @override
  Future<String> exportPortableArchive(
    String projectPath,
    String zipPath,
  ) async {
    await _assertManagedPath(projectPath);
    final report = await verifyPortableProject(projectPath);
    if (!report.isValid) {
      throw AudioProjectStoreUnavailable(
        'Project verification failed. Missing: ${report.missingMediaPaths.length}; corrupt: ${report.corruptMediaPaths.length}. Relink or repair media before export.',
      );
    }
    final manifestFile = File(projectPath);
    final json = jsonDecode(await manifestFile.readAsString());
    final session = AudioSession.fromJson(
      Map<String, dynamic>.from(json as Map),
    );
    final references = session.tracks
        .expand((track) => track.clips)
        .map((clip) => clip.mediaId)
        .toSet();
    if (references.isEmpty ||
        references.any((reference) => _isAbsoluteMediaPath(reference))) {
      throw const AudioProjectStoreUnavailable(
        'ZIP export requires a portable project with packaged media assets. Save the project first.',
      );
    }
    final folderNames = references
        .map((reference) => reference.replaceAll('\\', '/').split('/').first)
        .toSet();
    if (folderNames.length != 1) {
      throw const AudioProjectStoreUnavailable(
        'ZIP export requires all source WAV files to belong to one project asset folder.',
      );
    }
    final assetDirectory = Directory(
      '${manifestFile.parent.path}${Platform.pathSeparator}${folderNames.single}',
    );
    if (!await assetDirectory.exists()) {
      throw const AudioProjectStoreUnavailable(
        'The project asset folder is missing.',
      );
    }

    final output = File(zipPath);
    await output.parent.create(recursive: true);
    final temporary = File(
      '${output.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final backup = File('${output.path}.backup');
    final encoder = ZipFileEncoder();
    var created = false;
    var movedOldFile = false;
    try {
      encoder.create(temporary.path, level: DeflateLevel.bestSpeed);
      created = true;
      await encoder.addFile(
        manifestFile,
        manifestFile.uri.pathSegments.last,
      );
      await encoder.addDirectory(
        assetDirectory,
        includeDirName: true,
        followLinks: false,
        level: DeflateLevel.bestSpeed,
      );
      await encoder.close();
      created = false;

      if (await output.exists()) {
        if (await backup.exists()) await backup.delete();
        await output.rename(backup.path);
        movedOldFile = true;
      }
      await temporary.rename(output.path);
      if (movedOldFile && await backup.exists()) {
        await backup.delete();
      }
      return output.path;
    } catch (_) {
      if (created) {
        try {
          await encoder.close();
        } catch (_) {
          // Preserve the original export error.
        }
      }
      if (movedOldFile && !await output.exists() && await backup.exists()) {
        await backup.rename(output.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<String> importPortableArchive(String zipPath) async {
    final source = File(zipPath);
    if (!await source.exists()) {
      throw const AudioProjectStoreUnavailable('The ZIP archive does not exist.');
    }
    const maximumEntries = 10002;
    const maximumExpandedBytes = 20 * 1024 * 1024 * 1024;
    const maximumManifestBytes = 16 * 1024 * 1024;

    final rootDirectory = Directory(_directoryPath);
    await rootDirectory.create(recursive: true);
    final root = await rootDirectory.resolveSymbolicLinks();
    final stagingDirectory = Directory(
      '$root${Platform.pathSeparator}.import-${DateTime.now().microsecondsSinceEpoch}',
    );
    await stagingDirectory.create(recursive: true);
    final input = InputFileStream(source.path);

    try {
      final archive = ZipDecoder().decodeStream(input, verify: true);
      if (archive.isEmpty || archive.length > maximumEntries) {
        throw const AudioProjectStoreUnavailable(
          'The ZIP archive has an invalid number of entries.',
        );
      }

      final fileEntries = <String, ArchiveFile>{};
      String? manifestName;
      String? assetFolderName;
      var totalExpandedBytes = 0;
      for (final entry in archive) {
        if (entry.isSymbolicLink) {
          throw const AudioProjectStoreUnavailable(
            'ZIP projects cannot contain symbolic links.',
          );
        }
        final rawName = entry.name;
        if (rawName.isEmpty ||
            rawName.contains('\\') ||
            rawName.startsWith('/') ||
            RegExp(r'^[A-Za-z]:').hasMatch(rawName)) {
          throw const AudioProjectStoreUnavailable(
            'The ZIP archive contains an unsafe file path.',
          );
        }
        final isDirectory = !entry.isFile;
        final name = isDirectory && rawName.endsWith('/')
            ? rawName.substring(0, rawName.length - 1)
            : rawName;
        final segments = name.split('/');
        if (segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
          throw const AudioProjectStoreUnavailable(
            'The ZIP archive contains a path-traversal entry.',
          );
        }
        if (isDirectory) {
          if (segments.length != 1 ||
              !segments.single.contains('.assets-') ||
              entry.size != 0) {
            throw const AudioProjectStoreUnavailable(
              'The ZIP archive contains an unsupported directory entry.',
            );
          }
          if (assetFolderName != null && assetFolderName != segments.single) {
            throw const AudioProjectStoreUnavailable(
              'The ZIP archive contains multiple asset folders.',
            );
          }
          assetFolderName = segments.single;
          continue;
        }
        if (fileEntries.containsKey(name)) {
          throw const AudioProjectStoreUnavailable(
            'The ZIP archive contains duplicate file entries.',
          );
        }
        totalExpandedBytes += entry.size;
        if (entry.size < 0 || totalExpandedBytes > maximumExpandedBytes) {
          throw const AudioProjectStoreUnavailable(
            'The ZIP archive exceeds the permitted expanded size.',
          );
        }
        if (segments.length == 1 &&
            segments.single.endsWith('.aura.json')) {
          if (manifestName != null) {
            throw const AudioProjectStoreUnavailable(
              'The ZIP archive must contain exactly one Aura Voice project manifest.',
            );
          }
          manifestName = segments.single;
          if (entry.size > maximumManifestBytes) {
            throw const AudioProjectStoreUnavailable(
              'The project manifest is too large.',
            );
          }
        } else if (segments.length == 2 &&
            segments.first.contains('.assets-')) {
          if (assetFolderName != null && assetFolderName != segments.first) {
            throw const AudioProjectStoreUnavailable(
              'The ZIP archive contains more than one project asset folder.',
            );
          }
          assetFolderName = segments.first;
        } else {
          throw const AudioProjectStoreUnavailable(
            'The ZIP archive contains files outside the project manifest and asset folder.',
          );
        }
        fileEntries[name] = entry;
      }

      if (manifestName == null || assetFolderName == null) {
        throw const AudioProjectStoreUnavailable(
          'The ZIP archive is missing its project manifest or asset folder.',
        );
      }
      final manifestEntry = fileEntries[manifestName]!;
      final manifestBytes = manifestEntry.readBytes();
      if (manifestBytes == null) {
        throw const AudioProjectStoreUnavailable(
          'The project manifest could not be read from the ZIP archive.',
        );
      }
      final decodedManifest = jsonDecode(utf8.decode(manifestBytes));
      if (decodedManifest is! Map<String, dynamic>) {
        throw const FormatException('Invalid Aura Voice project manifest.');
      }
      final session = AudioSession.fromJson(decodedManifest);
      final referencedAssets = <String>{};
      for (final track in session.tracks) {
        for (final clip in track.clips) {
          final reference = clip.mediaId;
          if (_isAbsoluteMediaPath(reference)) {
            throw const AudioProjectStoreUnavailable(
              'This ZIP contains a non-portable project with absolute media paths.',
            );
          }
          final segments = reference.replaceAll('\\', '/').split('/');
          if (segments.length != 2 ||
              segments.first != assetFolderName ||
              segments.any((segment) =>
                  segment.isEmpty || segment == '.' || segment == '..')) {
            throw const AudioProjectStoreUnavailable(
              'The project manifest references a media path outside its packaged asset folder.',
            );
          }
          referencedAssets.add(segments.join('/'));
        }
      }
      if (referencedAssets.isEmpty) {
        throw const AudioProjectStoreUnavailable(
          'The ZIP project does not reference any packaged WAV assets.',
        );
      }
      final assetManifestName = '$assetFolderName/.aura-assets.json';
      final packagedAssetNames = fileEntries.keys
          .where((name) => name.startsWith('$assetFolderName/'))
          .toSet();
      if (packagedAssetNames.length != referencedAssets.length + 1 ||
          !packagedAssetNames.containsAll(referencedAssets) ||
          !packagedAssetNames.contains(assetManifestName)) {
        throw const AudioProjectStoreUnavailable(
          'The ZIP archive is missing one or more project assets or its integrity manifest.',
        );
      }

      final stagingManifest = File(
        '${stagingDirectory.path}${Platform.pathSeparator}$manifestName',
      );
      await stagingManifest.writeAsBytes(manifestBytes, flush: true);
      for (final name in packagedAssetNames) {
        final entry = fileEntries[name]!;
        final relativeName = name.replaceAll('/', Platform.pathSeparator);
        final outputPath =
            '${stagingDirectory.path}${Platform.pathSeparator}$relativeName';
        final destination = File(outputPath);
        await destination.parent.create(recursive: true);
        final output = OutputFileStream(destination.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (await destination.length() != entry.size) {
          throw AudioProjectStoreUnavailable(
            'The extracted project asset "$name" did not match its recorded size.',
          );
        }
      }

      final stagingStore = FileAudioProjectStore(
        directoryPath: stagingDirectory.path,
      );
      final stagedReport = await stagingStore._verifyPortableManifestWithoutManagedPath(
        stagingManifest.path,
      );
      if (!stagedReport.isValid || !stagedReport.hasChecksumManifest) {
        throw const AudioProjectStoreUnavailable(
          'The imported project failed SHA-256 asset verification.',
        );
      }

      final finalManifest = File(
        '$root${Platform.pathSeparator}$manifestName',
      );
      final finalAssetDirectory = Directory(
        '$root${Platform.pathSeparator}$assetFolderName',
      );
      if (await finalManifest.exists() ||
          await finalAssetDirectory.exists()) {
        throw const AudioProjectStoreUnavailable(
          'A project with the same manifest or asset folder is already imported. Rename or remove the existing project before importing this ZIP.',
        );
      }

      await Directory(
        '${stagingDirectory.path}${Platform.pathSeparator}$assetFolderName',
      ).rename(finalAssetDirectory.path);
      try {
        await stagingManifest.rename(finalManifest.path);
      } catch (_) {
        if (await finalAssetDirectory.exists()) {
          await finalAssetDirectory.rename(
            '${stagingDirectory.path}${Platform.pathSeparator}$assetFolderName',
          );
        }
        rethrow;
      }

      final report = await verifyPortableProject(finalManifest.path);
      if (!report.isValid || !report.hasChecksumManifest) {
        await finalManifest.delete();
        if (await finalAssetDirectory.exists()) {
          await finalAssetDirectory.delete(recursive: true);
        }
        throw const AudioProjectStoreUnavailable(
          'The imported project failed final integrity verification.',
        );
      }
      return finalManifest.path;
    } catch (_) {
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
      rethrow;
    } finally {
      input.closeSync();
    }
  }

  Future<AudioProjectIntegrityReport>
      _verifyPortableManifestWithoutManagedPath(String path) async {
    final manifestFile = File(path);
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Aura Voice project manifest.');
    }
    final session = AudioSession.fromJson(decoded);
    final references = session.tracks
        .expand((track) => track.clips)
        .map((clip) => clip.mediaId)
        .toSet();
    final missing = <String>[];
    final corrupt = <String>[];
    String? assetFolder;
    Map<String, dynamic>? checksumFiles;
    for (final reference in references) {
      final segments = reference.replaceAll('\\', '/').split('/');
      if (segments.length != 2 ||
          segments.any((segment) =>
              segment.isEmpty || segment == '.' || segment == '..') ||
          (assetFolder != null && assetFolder != segments.first)) {
        corrupt.add(reference);
        continue;
      }
      assetFolder = segments.first;
      final assetPath =
          '${manifestFile.parent.path}${Platform.pathSeparator}'
          '${segments.first}${Platform.pathSeparator}${segments.last}';
      final file = File(assetPath);
      if (!await file.exists()) {
        missing.add(reference);
      }
    }
    if (assetFolder != null) {
      final metadataFile = File(
        '${manifestFile.parent.path}${Platform.pathSeparator}$assetFolder'
        '${Platform.pathSeparator}.aura-assets.json',
      );
      if (await metadataFile.exists()) {
        try {
          final metadata = jsonDecode(await metadataFile.readAsString());
          if (metadata is! Map<String, dynamic> ||
              metadata['schemaVersion'] != 1 ||
              metadata['assetFolder'] != assetFolder ||
              metadata['files'] is! Map<String, dynamic>) {
            throw const FormatException('Invalid asset inventory.');
          }
          checksumFiles = metadata['files'] as Map<String, dynamic>;
        } catch (_) {
          corrupt.addAll(references);
        }
      }
    }
    var checked = 0;
    if (checksumFiles != null) {
      for (final reference in references) {
        final segments = reference.replaceAll('\\', '/').split('/');
        final expected = checksumFiles[segments.last];
        if (expected is! Map<String, dynamic>) {
          corrupt.add(reference);
          continue;
        }
        final file = File(
          '${manifestFile.parent.path}${Platform.pathSeparator}'
          '${segments.first}${Platform.pathSeparator}${segments.last}',
        );
        if (!await file.exists()) continue;
        final stat = await file.stat();
        final expectedSize = expected['sizeBytes'];
        final expectedHash = expected['sha256'];
        if (expectedSize is! int ||
            expectedHash is! String ||
            stat.size != expectedSize) {
          corrupt.add(reference);
          continue;
        }
        final digest = await sha256.bind(file.openRead()).first;
        checked++;
        if (digest.toString().toLowerCase() != expectedHash.toLowerCase()) {
          corrupt.add(reference);
        }
      }
    }
    return AudioProjectIntegrityReport(
      checkedAssetCount: checked,
      missingMediaPaths: missing,
      corruptMediaPaths: corrupt,
      hasChecksumManifest: checksumFiles != null,
    );
  }

  @override
  Future<String> saveRecoverySnapshot(AudioSession session) async {
    final directory = await _ensureRecoveryDirectory();
    await _recoverRecoveryBackups(directory);
    final filename =
        'AuraRecovery_${_safeId(session.id)}.recovery.aura.json';
    final file = File(
      '${directory.path}${Platform.pathSeparator}$filename',
    );
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final backup = File('${file.path}.backup');
    final manifest = jsonEncode(session.toJson());
    final sink = await temporary.open(mode: FileMode.write);
    try {
      await sink.writeString(manifest);
      await sink.flush();
    } finally {
      await sink.close();
    }

    var movedOldFile = false;
    try {
      if (await file.exists()) {
        if (await backup.exists()) {
          await backup.delete();
        }
        await file.rename(backup.path);
        movedOldFile = true;
      }
      await temporary.rename(file.path);
      if (movedOldFile && await backup.exists()) {
        await backup.delete();
      }
      return file.path;
    } catch (_) {
      if (movedOldFile && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  @override
  Future<AudioSession> loadRecoverySnapshot(String path) async {
    await _assertManagedRecoveryPath(path);
    final source = await File(path).readAsString();
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid Aura Voice recovery snapshot.');
    }
    return AudioSession.fromJson(json);
  }

  @override
  Future<List<AudioProjectSummary>> listRecoverySnapshots() async {
    final rootDirectory = Directory(_directoryPath);
    if (!await rootDirectory.exists()) {
      return const [];
    }
    final root = await rootDirectory.resolveSymbolicLinks();
    final recoveryDirectory = Directory(
      '$root${Platform.pathSeparator}Recovery',
    );
    if (!await recoveryDirectory.exists()) {
      return const [];
    }
    final recoveryRoot = await recoveryDirectory.resolveSymbolicLinks();
    if (!_isPathWithin(recoveryRoot, root)) {
      throw const AudioProjectStoreUnavailable(
        'The recovery folder must remain inside the Aura Voice Projects folder.',
      );
    }
    await _recoverRecoveryBackups(Directory(recoveryRoot));

    final summaries = <AudioProjectSummary>[];
    await for (final entity
        in Directory(recoveryRoot).list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.recovery.aura.json')) {
        continue;
      }
      try {
        final source = await entity.readAsString();
        final json = jsonDecode(source);
        if (json is! Map<String, dynamic>) {
          continue;
        }
        final session = AudioSession.fromJson(json);
        final stat = await entity.stat();
        summaries.add(
          AudioProjectSummary(
            path: entity.path,
            title: session.title,
            modifiedAt: stat.modified,
            sampleRate: session.sampleRate,
            trackCount: session.tracks.length,
          ),
        );
      } catch (_) {
        // Ignore damaged snapshots; they must not block valid recovery points.
      }
    }
    summaries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return summaries;
  }

  @override
  Future<void> deleteRecoverySnapshot(String path) async {
    await _assertManagedRecoveryPath(path);
    await File(path).delete();
    final backup = File('$path.backup');
    if (await FileSystemEntity.type(backup.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await backup.delete();
    }
  }

  @override
  Future<AudioSession> load(String path) async {
    await _assertManagedPath(path);
    final file = File(path);
    if (!await file.exists()) {
      throw const AudioProjectStoreUnavailable('The project file no longer exists.');
    }
    final source = await file.readAsString();
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid Aura Voice project manifest.');
    }
    final session = AudioSession.fromJson(json);
    return _resolveSessionMedia(session, file.parent.path);
  }

  @override
  Future<List<AudioProjectSummary>> listProjects() async {
    final directory = Directory(_directoryPath);
    if (!await directory.exists()) return const [];
    await _recoverBackups(directory);
    final summaries = <AudioProjectSummary>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.aura.json')) {
        continue;
      }
      try {
        final source = await entity.readAsString();
        final json = jsonDecode(source);
        if (json is! Map<String, dynamic>) continue;
        final session = AudioSession.fromJson(json);
        final stat = await entity.stat();
        summaries.add(
          AudioProjectSummary(
            path: entity.path,
            title: session.title,
            modifiedAt: stat.modified,
            sampleRate: session.sampleRate,
            trackCount: session.tracks.length,
          ),
        );
      } catch (_) {
        // Ignore invalid manifests or files changed while the list was read.
      }
    }
    summaries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return summaries;
  }

  Future<void> _recoverBackups(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.aura.json.backup')) {
        continue;
      }
      final backup = entity;
      final targetPath = backup.path.substring(
        0,
        backup.path.length - '.backup'.length,
      );
      final target = File(targetPath);
      try {
        if (await target.exists()) {
          await backup.delete();
        } else {
          await backup.rename(target.path);
        }
      } on FileSystemException {
        // A recovery file may be locked or changed by another process.
      }
    }
  }

  @override
  Future<List<AudioProjectSummary>> findProjectsUsingMedia(String mediaPath) async {
    final summaries = await listProjects();
    final matches = <AudioProjectSummary>[];
    for (final summary in summaries) {
      try {
        final session = await load(summary.path);
        final referencesMedia = session.tracks.any(
          (track) => track.clips.any((clip) => clip.mediaId == mediaPath),
        );
        if (referencesMedia) matches.add(summary);
      } catch (_) {
        // Skip a project that became invalid or disappeared during the scan.
      }
    }
    return matches;
  }

  @override
  Future<void> delete(String path) async {
    await _assertManagedPath(path);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> _recoverRecoveryBackups(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.recovery.aura.json.backup')) {
        continue;
      }
      final backup = entity;
      final targetPath = backup.path.substring(
        0,
        backup.path.length - '.backup'.length,
      );
      final target = File(targetPath);
      try {
        if (await target.exists()) {
          await backup.delete();
        } else {
          await backup.rename(target.path);
        }
      } on FileSystemException {
        // Keep a locked recovery backup for the next application launch.
      }
    }
  }

  Future<Directory> _ensureRecoveryDirectory() async {
    final rootDirectory = Directory(_directoryPath);
    await rootDirectory.create(recursive: true);
    final root = await rootDirectory.resolveSymbolicLinks();
    final recoveryDirectory = Directory(
      '$root${Platform.pathSeparator}Recovery',
    );
    await recoveryDirectory.create(recursive: true);
    final recoveryRoot = await recoveryDirectory.resolveSymbolicLinks();
    if (!_isPathWithin(recoveryRoot, root)) {
      throw const AudioProjectStoreUnavailable(
        'The recovery folder must remain inside the Aura Voice Projects folder.',
      );
    }
    return Directory(recoveryRoot);
  }

  Future<void> _assertManagedRecoveryPath(String path) async {
    if (!path.toLowerCase().endsWith('.recovery.aura.json') ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const AudioProjectStoreUnavailable(
        'Only regular recovery snapshots inside the Recovery folder can be changed.',
      );
    }
    await _assertManagedPath(path);
    final root = await Directory(_directoryPath).resolveSymbolicLinks();
    final recoveryDirectory = Directory(
      '$root${Platform.pathSeparator}Recovery',
    );
    if (!await recoveryDirectory.exists()) {
      throw const AudioProjectStoreUnavailable(
        'The recovery snapshot folder no longer exists.',
      );
    }
    final recoveryRoot = await recoveryDirectory.resolveSymbolicLinks();
    if (!_isPathWithin(recoveryRoot, root)) {
      throw const AudioProjectStoreUnavailable(
        'The recovery folder must remain inside the Aura Voice Projects folder.',
      );
    }
    final lexicalPath = File(path).absolute.path;
    final resolvedPath = await File(path).resolveSymbolicLinks();
    if (!_isPathWithin(lexicalPath, recoveryRoot) ||
        !_isPathWithin(resolvedPath, recoveryRoot)) {
      throw const AudioProjectStoreUnavailable(
        'Only recovery snapshots inside the Recovery folder can be changed.',
      );
    }
  }

  Future<void> _deleteRecoverySnapshotForId(String id) async {
    final rootDirectory = Directory(_directoryPath);
    if (!await rootDirectory.exists()) {
      return;
    }
    final root = await rootDirectory.resolveSymbolicLinks();
    final recoveryDirectory = Directory(
      '$root${Platform.pathSeparator}Recovery',
    );
    if (!await recoveryDirectory.exists()) {
      return;
    }
    final recoveryRoot = await recoveryDirectory.resolveSymbolicLinks();
    if (!_isPathWithin(recoveryRoot, root)) {
      return;
    }
    final filename =
        '$recoveryRoot${Platform.pathSeparator}AuraRecovery_${_safeId(id)}.recovery.aura.json';
    for (final path in [filename, '$filename.backup']) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(path).delete();
      }
    }
  }

  bool _isPathWithin(String candidate, String root) {
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedCandidate =
        Platform.isWindows ? candidate.toLowerCase() : candidate;
    return normalizedCandidate.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  }

  Future<void> _assertManagedPath(String path) async {
    final file = File(path);
    if (!path.toLowerCase().endsWith('.aura.json') ||
        !await file.exists()) {
      throw const AudioProjectStoreUnavailable(
        'Only existing Aura Voice project manifests can be changed.',
      );
    }
    final root = await Directory(_directoryPath).resolveSymbolicLinks();
    final candidate = await file.resolveSymbolicLinks();
    final separator = Platform.pathSeparator;
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedCandidate =
        Platform.isWindows ? candidate.toLowerCase() : candidate;
    if (!normalizedCandidate.startsWith('$normalizedRoot$separator')) {
      throw const AudioProjectStoreUnavailable(
        'Only Aura Voice project manifests inside the Projects folder can be changed.',
      );
    }
  }

  Future<AudioSession> _resolveSessionMedia(
    AudioSession session,
    String projectDirectory,
  ) async {
    final tracks = <AudioTrack>[];
    for (final track in session.tracks) {
      final clips = <AudioClip>[];
      for (final clip in track.clips) {
        final resolvedPath =
            await _resolvePortableMediaPath(clip.mediaId, projectDirectory);
        clips.add(
          AudioClip(
            id: clip.id,
            mediaId: resolvedPath,
            startFrame: clip.startFrame,
            sourceStartFrame: clip.sourceStartFrame,
            durationFrames: clip.durationFrames,
            gain: clip.gain,
            pan: clip.pan,
            muted: clip.muted,
            fadeInFrames: clip.fadeInFrames,
            fadeOutFrames: clip.fadeOutFrames,
          ),
        );
      }
      tracks.add(
        AudioTrack(
          id: track.id,
          name: track.name,
          kind: track.kind,
          gain: track.gain,
          pan: track.pan,
          muted: track.muted,
          solo: track.solo,
          armed: track.armed,
          highPassHz: track.highPassHz,
          compressorThreshold: track.compressorThreshold,
          compressorRatio: track.compressorRatio,
          clips: clips,
        ),
      );
    }
    return AudioSession(
      id: session.id,
      title: session.title,
      sampleRate: session.sampleRate,
      channels: session.channels,
      bitDepth: session.bitDepth,
      tracks: tracks,
      markers: session.markers,
    );
  }

  Future<String> _resolvePortableMediaPath(
    String mediaPath,
    String projectDirectory,
  ) async {
    if (_isAbsoluteMediaPath(mediaPath)) return mediaPath;
    final segments = mediaPath.replaceAll('\\', '/').split('/');
    if (segments.isEmpty ||
        segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
      throw const FormatException(
        'The project contains an unsafe relative media path.',
      );
    }
    final root = await Directory(projectDirectory).resolveSymbolicLinks();
    var candidate = root;
    for (final segment in segments) {
      candidate = '$candidate${Platform.pathSeparator}$segment';
    }
    candidate = File(candidate).absolute.path;
    if (!_isPathWithin(candidate, root)) {
      throw const FormatException(
        'The project media path points outside its project folder.',
      );
    }
    final parent = File(candidate).parent;
    if (await parent.exists()) {
      final resolvedParent = await parent.resolveSymbolicLinks();
      if (resolvedParent != root && !_isPathWithin(resolvedParent, root)) {
        throw const FormatException(
          'A project asset folder resolves outside its project folder.',
        );
      }
    }
    final file = File(candidate);
    if (await file.exists()) {
      final resolvedFile = await file.resolveSymbolicLinks();
      if (!_isPathWithin(resolvedFile, root)) {
        throw const FormatException(
          'A project media file resolves outside its project folder.',
        );
      }
      return resolvedFile;
    }
    return candidate;
  }

  bool _isAbsoluteMediaPath(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  Future<void> _removeSupersededAssetFolders(
    String root,
    String prefix,
    String keepName,
  ) async {
    await for (final entity in Directory(root).list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith(prefix) && name != keepName) {
        await entity.delete(recursive: true);
      }
    }
  }

  String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _safeId(String value) {
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (normalized.isEmpty) {
      throw const AudioProjectStoreUnavailable('Project id is invalid.');
    }
    return normalized.length > 80 ? normalized.substring(0, 80) : normalized;
  }

  static String _defaultDirectoryPath() {
    final environment = Platform.environment;
    final home = environment['USERPROFILE'] ??
        environment['HOME'] ??
        Directory.current.path;
    return '$home${Platform.pathSeparator}Documents'
        '${Platform.pathSeparator}Aura Voice Studio'
        '${Platform.pathSeparator}Projects';
  }
}
