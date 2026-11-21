import 'dart:convert';
import 'dart:io';

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
    return AudioSession.fromJson(json);
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
