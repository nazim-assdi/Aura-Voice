import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'audio_waveform_contract.dart';

AudioWaveformService createAudioWaveformService() =>
    const FileAudioWaveformService();

/// Reads WAV frames in bounded chunks and calculates real per-bucket peaks.
/// The full recording is never loaded into memory.
class FileAudioWaveformService implements AudioWaveformService {
  const FileAudioWaveformService({this.cacheDirectoryPath});

  /// Optional cache location, mainly useful for tests and portable setups.
  final String? cacheDirectoryPath;

  @override
  Future<AudioWaveformData> analyze(
    String path, {
    int peakCount = 320,
  }) async {
    if (peakCount < 16 || peakCount > 4096) {
      throw ArgumentError.value(
        peakCount,
        'peakCount',
        'Must be between 16 and 4096.',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      throw const AudioWaveformUnavailable('The WAV file no longer exists.');
    }
    final sourceStat = await file.stat();
    final canonicalPath = await file.resolveSymbolicLinks();
    final cacheFile = File(
      '${_cacheDirectoryPath()}'
      '${Platform.pathSeparator}'
      '${_cacheKey(canonicalPath, peakCount)}.json',
    );
    final cached = await _readCachedWaveform(
      cacheFile,
      sourcePath: canonicalPath,
      fileSize: sourceStat.size,
      modifiedMicros: sourceStat.modified.microsecondsSinceEpoch,
      peakCount: peakCount,
    );
    if (cached != null) return cached;
    final random = await file.open(mode: FileMode.read);
    try {
      final fileLength = await random.length();
      if (fileLength < 44) {
        throw const FormatException('The WAV file is too small.');
      }

      final riff = await _readAvailable(random, 12);
      if (riff.length != 12 ||
          _fourCc(riff, 0) != 'RIFF' ||
          _fourCc(riff, 8) != 'WAVE') {
        throw const FormatException('Invalid RIFF/WAVE header.');
      }

      int? formatTag;
      int? channels;
      int? sampleRate;
      int? bitsPerSample;
      int? blockAlign;
      int? dataBytes;
      int? dataOffset;
      var position = 12;

      while (position + 8 <= fileLength &&
          (formatTag == null || dataBytes == null || dataOffset == null)) {
        await random.setPosition(position);
        final header = await _readAvailable(random, 8);
        if (header.length != 8) break;
        final id = _fourCc(header, 0);
        final length = ByteData.sublistView(header).getUint32(4, Endian.little);
        final chunkStart = position + 8;
        final chunkEnd = chunkStart + length;
        if (chunkEnd > fileLength || chunkEnd < chunkStart) {
          throw const FormatException('WAV chunk exceeds file boundary.');
        }

        if (id == 'fmt ') {
          if (length < 16 || length > 4096) {
            throw const FormatException('Unsupported WAV format chunk.');
          }
          await random.setPosition(chunkStart);
          final format = await _readAvailable(random, length);
          if (format.length != length) {
            throw const FormatException('Incomplete WAV format chunk.');
          }
          final data = ByteData.sublistView(format);
          formatTag = data.getUint16(0, Endian.little);
          channels = data.getUint16(2, Endian.little);
          sampleRate = data.getUint32(4, Endian.little);
          blockAlign = data.getUint16(12, Endian.little);
          bitsPerSample = data.getUint16(14, Endian.little);
        } else if (id == 'data') {
          dataBytes = length;
          dataOffset = chunkStart;
        }

        position = chunkEnd + (length.isOdd ? 1 : 0);
      }

      if (formatTag == null ||
          channels == null ||
          sampleRate == null ||
          bitsPerSample == null ||
          blockAlign == null ||
          dataBytes == null ||
          dataOffset == null) {
        throw const FormatException('WAV is missing format or sample data.');
      }
      if (channels < 1 ||
          channels > 8 ||
          sampleRate < 8000 ||
          sampleRate > 384000 ||
          blockAlign <= 0 ||
          dataBytes % blockAlign != 0 ||
          !((formatTag == 1 && [8, 16, 24, 32].contains(bitsPerSample)) ||
              (formatTag == 3 && bitsPerSample == 32))) {
        throw const FormatException('Unsupported WAV encoding or channel layout.');
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      if (blockAlign != bytesPerSample * channels) {
        throw const FormatException('WAV block alignment does not match its format.');
      }
      final totalFrames = dataBytes ~/ blockAlign;
      if (totalFrames == 0) {
        throw const FormatException('WAV contains no audio frames.');
      }

      final targetBuckets = totalFrames < peakCount ? totalFrames : peakCount;
      final peaks = <double>[];
      var currentPeak = 0.0;
      var framesRead = 0;
      var bucketIndex = 0;
      var nextBucketEnd = (totalFrames / targetBuckets).ceil();
      var bytesRemaining = dataBytes;
      var bytesPerRead = (64 * 1024 ~/ blockAlign) * blockAlign;
      if (bytesPerRead < blockAlign) bytesPerRead = blockAlign;

      await random.setPosition(dataOffset);
      while (bytesRemaining > 0) {
        final count = bytesRemaining < bytesPerRead
            ? bytesRemaining
            : bytesPerRead;
        final chunk = await _readAvailable(random, count);
        if (chunk.isEmpty || chunk.length % blockAlign != 0) {
          throw const FormatException('Incomplete audio data chunk.');
        }
        final view = ByteData.sublistView(chunk);
        final framesInChunk = chunk.length ~/ blockAlign;

        for (var frame = 0; frame < framesInChunk; frame++) {
          final frameOffset = frame * blockAlign;
          for (var channel = 0; channel < channels; channel++) {
            final sampleOffset = frameOffset + channel * bytesPerSample;
            final value = _decodeSample(
              view,
              sampleOffset,
              formatTag,
              bitsPerSample,
            );
            final magnitude = value.abs();
            if (magnitude > currentPeak) currentPeak = magnitude;
          }
          framesRead++;
          if (framesRead >= nextBucketEnd) {
            peaks.add(currentPeak.clamp(0.0, 1.0).toDouble());
            currentPeak = 0;
            bucketIndex++;
            if (bucketIndex < targetBuckets) {
              nextBucketEnd =
                  ((bucketIndex + 1) * totalFrames / targetBuckets).ceil();
            }
          }
        }
        bytesRemaining -= chunk.length;
      }

      final result = AudioWaveformData(
        peaks: Float32List.fromList(peaks),
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        frameCount: totalFrames,
      );
      final finalStat = await file.stat();
      if (finalStat.size == sourceStat.size &&
          finalStat.modified.microsecondsSinceEpoch ==
              sourceStat.modified.microsecondsSinceEpoch) {
        await _writeCachedWaveform(
          cacheFile,
          result,
          sourcePath: canonicalPath,
          fileSize: sourceStat.size,
          modifiedMicros: sourceStat.modified.microsecondsSinceEpoch,
          peakCount: peakCount,
        );
      }
      return result;
    } finally {
      await random.close();
    }
  }

  String _cacheDirectoryPath() {
    if (cacheDirectoryPath != null && cacheDirectoryPath!.trim().isNotEmpty) {
      return cacheDirectoryPath!;
    }
    final environment = Platform.environment;
    final home = environment['USERPROFILE'] ??
        environment['HOME'] ??
        Directory.current.path;
    return '$home${Platform.pathSeparator}Documents'
        '${Platform.pathSeparator}Aura Voice Studio'
        '${Platform.pathSeparator}Cache'
        '${Platform.pathSeparator}Waveforms';
  }

  String _cacheKey(String sourcePath, int peakCount) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$sourcePath|$peakCount')) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<AudioWaveformData?> _readCachedWaveform(
    File cacheFile, {
    required String sourcePath,
    required int fileSize,
    required int modifiedMicros,
    required int peakCount,
  }) async {
    if (!await cacheFile.exists()) return null;
    try {
      final decoded = jsonDecode(await cacheFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != 1 ||
          decoded['sourcePath'] != sourcePath ||
          decoded['fileSize'] != fileSize ||
          decoded['modifiedMicros'] != modifiedMicros ||
          decoded['peakCount'] != peakCount) {
        return null;
      }
      final frameCount = decoded['frameCount'];
      if (frameCount is! int || frameCount <= 0) return null;
      final expectedPeakCount =
          frameCount < peakCount ? frameCount : peakCount;
      final rawPeaks = decoded['peaks'];
      if (rawPeaks is! List || rawPeaks.length != expectedPeakCount) {
        return null;
      }
      final peaks = rawPeaks.map((value) {
        if (value is! num || !value.isFinite || value < 0 || value > 1) {
          throw const FormatException('Invalid waveform cache peak.');
        }
        return value.toDouble();
      }).toList();
      final sampleRate = decoded['sampleRate'];
      final channels = decoded['channels'];
      final bitsPerSample = decoded['bitsPerSample'];
      if (sampleRate is! int ||
          channels is! int ||
          bitsPerSample is! int ||
          sampleRate < 1 ||
          channels < 1) {
        return null;
      }
      return AudioWaveformData(
        peaks: peaks,
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        frameCount: frameCount,
      );
    } catch (_) {
      // A damaged cache must never block normal WAV analysis.
      return null;
    }
  }

  Future<void> _writeCachedWaveform(
    File cacheFile,
    AudioWaveformData waveform, {
    required String sourcePath,
    required int fileSize,
    required int modifiedMicros,
    required int peakCount,
  }) async {
    try {
      await cacheFile.parent.create(recursive: true);
      final temporary = File(
        '${cacheFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      final payload = jsonEncode({
        'schemaVersion': 1,
        'sourcePath': sourcePath,
        'fileSize': fileSize,
        'modifiedMicros': modifiedMicros,
        'peakCount': peakCount,
        'sampleRate': waveform.sampleRate,
        'channels': waveform.channels,
        'bitsPerSample': waveform.bitsPerSample,
        'frameCount': waveform.frameCount,
        'peaks': waveform.peaks.toList(),
      });
      try {
        final sink = await temporary.open(mode: FileMode.write);
        try {
          await sink.writeString(payload);
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (await cacheFile.exists()) await cacheFile.delete();
        await temporary.rename(cacheFile.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    } catch (_) {
      // Cache writes are best-effort; audio analysis remains authoritative.
    }
  }

  static Future<Uint8List> _readAvailable(
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

  static double _decodeSample(
    ByteData data,
    int offset,
    int formatTag,
    int bitsPerSample,
  ) {
    if (formatTag == 3) {
      final value = data.getFloat32(offset, Endian.little);
      if (!value.isFinite) {
        throw const FormatException('WAV contains NaN or infinite audio samples.');
      }
      return value;
    }
    switch (bitsPerSample) {
      case 8:
        return (data.getUint8(offset) - 128) / 128.0;
      case 16:
        return data.getInt16(offset, Endian.little) / 32768.0;
      case 24:
        final raw = data.getUint8(offset) |
            (data.getUint8(offset + 1) << 8) |
            (data.getUint8(offset + 2) << 16);
        final signed = (raw & 0x800000) == 0
            ? raw
            : raw - 0x1000000;
        return signed / 8388608.0;
      case 32:
        return data.getInt32(offset, Endian.little) / 2147483648.0;
      default:
        throw const FormatException('Unsupported WAV bit depth.');
    }
  }

  static String _fourCc(Uint8List bytes, int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
}
