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
