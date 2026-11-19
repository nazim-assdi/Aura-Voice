import 'dart:io';
import 'dart:typed_data';

import 'audio_library_contract.dart';

AudioLibraryService createAudioLibraryService({String? directoryPath}) =>
    FileAudioLibraryService(directoryPath: directoryPath);

/// Filesystem-backed local WAV library.
///
/// WAV files in this recordings directory are listed. Metadata is read from
/// RIFF chunks without loading the audio payload.
class FileAudioLibraryService implements AudioLibraryService {
  FileAudioLibraryService({String? directoryPath})
      : _directoryPath = directoryPath ?? _defaultDirectoryPath();

  final String _directoryPath;

  @override
  String get directoryPath => _directoryPath;

  @override
  Future<List<AudioLibraryRecording>> listRecordings() async {
    final directory = Directory(_directoryPath);
    if (!await directory.exists()) return const [];

    final recordings = <AudioLibraryRecording>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !_isManagedWav(entity.path)) continue;
      try {
        final recording = await _readMetadata(entity);
        if (recording != null) recordings.add(recording);
      } on FileSystemException {
        // Ignore files being deleted or changed by another process.
      } on FormatException {
        // An incomplete or invalid WAV should not break the whole library.
      }
    }
    recordings.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return recordings;
  }

  @override
  Future<AudioLibraryRecording> renameRecording(
    AudioLibraryRecording recording,
    String newName,
  ) async {
    await _assertManagedPath(recording.path);
    final normalized = _normalizeName(newName);
    if (normalized.isEmpty) {
      throw const AudioLibraryUnavailable('Enter a valid recording name.');
    }
    final source = File(recording.path);
    if (!await source.exists()) {
      throw const AudioLibraryUnavailable('This recording no longer exists.');
    }
    final extension = '.wav';
    final destination = await _uniqueDestination(normalized, extension);
    final renamed = await source.rename(destination.path);
    final metadata = await _readMetadata(renamed);
    if (metadata == null) {
      throw const AudioLibraryUnavailable('The renamed WAV file could not be read.');
    }
    return metadata;
  }

  @override
  Future<void> deleteRecording(AudioLibraryRecording recording) async {
    _assertManagedPath(recording.path);
    final file = File(recording.path);
    if (await file.exists()) await file.delete();
  }

  Future<AudioLibraryRecording?> _readMetadata(File file) async {
    final random = await file.open(mode: FileMode.read);
    try {
      final fileLength = await random.length();
      if (fileLength < 44) return null;

      final riffHeader = await _readAvailable(random, 12);
      if (riffHeader.length != 12 ||
          _fourCc(riffHeader, 0) != 'RIFF' ||
          _fourCc(riffHeader, 8) != 'WAVE') {
        return null;
      }

      int? formatTag;
      int? channels;
      int? sampleRate;
      int? bitsPerSample;
      int? blockAlign;
      int? dataBytes;

      var position = 12;
      while (position + 8 <= fileLength &&
          (formatTag == null || dataBytes == null)) {
        await random.setPosition(position);
        final chunkHeader = await _readAvailable(random, 8);
        if (chunkHeader.length != 8) break;
        final chunkId = _fourCc(chunkHeader, 0);
        final chunkLength = ByteData.sublistView(chunkHeader)
            .getUint32(4, Endian.little);
        final chunkStart = position + 8;
        final chunkEnd = chunkStart + chunkLength;
        if (chunkEnd > fileLength || chunkEnd < chunkStart) {
          throw const FormatException('WAV chunk exceeds the file boundary.');
        }

        if (chunkId == 'fmt ') {
          if (chunkLength < 16 || chunkLength > 4096) {
            throw const FormatException('Invalid WAV format chunk.');
          }
          await random.setPosition(chunkStart);
          final format = await _readAvailable(random, chunkLength);
          if (format.length != chunkLength) {
            throw const FormatException('Incomplete WAV format chunk.');
          }
          final data = ByteData.sublistView(format);
          formatTag = data.getUint16(0, Endian.little);
          channels = data.getUint16(2, Endian.little);
          sampleRate = data.getUint32(4, Endian.little);
          blockAlign = data.getUint16(12, Endian.little);
          bitsPerSample = data.getUint16(14, Endian.little);
        } else if (chunkId == 'data') {
          dataBytes = chunkLength;
        }

        position = chunkEnd + (chunkLength.isOdd ? 1 : 0);
      }

      if (formatTag == null ||
          channels == null ||
          sampleRate == null ||
          bitsPerSample == null ||
          blockAlign == null ||
          dataBytes == null) {
        throw const FormatException('Unsupported or incomplete WAV metadata.');
      }

      if (channels < 1 ||
          channels > 8 ||
          sampleRate < 8000 ||
          sampleRate > 384000 ||
          blockAlign <= 0 ||
          dataBytes % blockAlign != 0 ||
          !((formatTag == 1 && [8, 16, 24, 32].contains(bitsPerSample)) ||
              (formatTag == 3 && bitsPerSample == 32))) {
        throw const FormatException('Unsupported or incomplete WAV metadata.');
      }

      final frames = dataBytes ~/ blockAlign;
      final duration = Duration(
        microseconds: (frames * 1000000 / sampleRate).round(),
      );
      final stat = await file.stat();
      return AudioLibraryRecording(
        path: file.path,
        name: _displayName(file.path),
        modifiedAt: stat.modified,
        sizeBytes: stat.size,
        duration: duration,
        frameCount: frames,
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
      );
    } finally {
      await random.close();
    }
  }

  Future<File> _uniqueDestination(String name, String extension) async {
    final directory = Directory(_directoryPath);
    await directory.create(recursive: true);
    var candidate = File(
      '${directory.path}${Platform.pathSeparator}$name$extension',
    );
    if (!await candidate.exists()) return candidate;
    for (var suffix = 2; suffix < 10000; suffix++) {
      candidate = File(
        '${directory.path}${Platform.pathSeparator}$name ($suffix)$extension',
      );
      if (!await candidate.exists()) return candidate;
    }
    throw const AudioLibraryUnavailable(
      'Could not create a unique recording name.',
    );
  }

  Future<void> _assertManagedPath(String path) async {
    final file = File(path);
    if (!_isManagedWav(path) || !await file.exists()) {
      throw const AudioLibraryUnavailable(
        'Only existing WAV recordings can be changed.',
      );
    }
    final root = await Directory(_directoryPath).resolveSymbolicLinks();
    final candidate = await file.resolveSymbolicLinks();
    final separator = Platform.pathSeparator;
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedCandidate =
        Platform.isWindows ? candidate.toLowerCase() : candidate;
    if (!normalizedCandidate.startsWith('$normalizedRoot$separator')) {
      throw const AudioLibraryUnavailable(
        'Only WAV recordings inside the Aura Voice Studio library can be changed.',
      );
    }
  }

  bool _isManagedWav(String path) {
    final filename = path.split(Platform.pathSeparator).last;
    return filename.toLowerCase().endsWith('.wav');
  }

  String _displayName(String path) {
    final fileName = path.split(Platform.pathSeparator).last;
    return fileName.toLowerCase().endsWith('.wav')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
  }

  String _normalizeName(String value) {
    var name = value.trim();
    if (name.toLowerCase().endsWith('.wav')) {
      name = name.substring(0, name.length - 4);
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.length > 90) name = name.substring(0, 90).trim();
    return name;
  }

  Future<Uint8List> _readAvailable(
    RandomAccessFile file,
    int byteCount,
  ) async {
    final builder = BytesBuilder(copy: false);
    var remaining = byteCount;
    while (remaining > 0) {
      final part = await file.read(remaining);
      if (part.isEmpty) break;
      builder.add(part);
      remaining -= part.length;
    }
    return builder.takeBytes();
  }

  String _fourCc(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));

  static String _defaultDirectoryPath() {
    final environment = Platform.environment;
    final home = environment['USERPROFILE'] ??
        environment['HOME'] ??
        Directory.current.path;
    return '$home${Platform.pathSeparator}Documents'
        '${Platform.pathSeparator}Aura Voice Studio'
        '${Platform.pathSeparator}Recordings';
  }
}
