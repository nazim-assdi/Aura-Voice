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
    final temporary = File('${file.path}.tmp');
    final manifest = jsonEncode(session.toJson());
    final random = await temporary.open(mode: FileMode.write);
    try {
      await random.writeString(manifest);
      await random.flush();
    } finally {
      await random.close();
    }
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    return file.path;
  }

  @override
  Future<AudioSession> load(String path) async {
    _assertManagedPath(path);
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
      } on FormatException {
        // Ignore invalid manifests; a damaged project should not hide others.
      } on FileSystemException {
        // Ignore a project that was removed while the list was being read.
      }
    }
    summaries.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return summaries;
  }

  @override
  Future<void> delete(String path) async {
    _assertManagedPath(path);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  void _assertManagedPath(String path) {
    final root = Directory(_directoryPath).absolute.path;
    final candidate = File(path).absolute.path;
    final separator = Platform.pathSeparator;
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedCandidate =
        Platform.isWindows ? candidate.toLowerCase() : candidate;
    if (!normalizedCandidate.startsWith('$normalizedRoot$separator') ||
        !candidate.toLowerCase().endsWith('.aura.json')) {
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
