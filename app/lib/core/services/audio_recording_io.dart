import 'dart:io';
import 'dart:typed_data';

import 'audio_recording_contract.dart';

AudioRecordingWriter createAudioRecordingWriter({String? directoryPath}) =>
    FileAudioRecordingWriter(directoryPath: directoryPath);

/// Bounded-memory 24-bit integer PCM WAV writer.
///
/// Samples are written in small chunks as they arrive. The audio-device
/// callback never touches this writer; only the non-realtime consumer does.
class FileAudioRecordingWriter implements AudioRecordingWriter {
  FileAudioRecordingWriter({String? directoryPath})
      : _requestedDirectoryPath = directoryPath;

  final String? _requestedDirectoryPath;
  RandomAccessFile? _file;
  String? _filePath;
  int _sampleRate = 0;
  int _channels = 0;
  int _dataBytes = 0;
  bool _finished = false;

  static const int _bitsPerSample = 24;
  static const int _bytesPerSample = 3;
  static const int _maxDataBytes = 0xFFFFFFFF - 36;

  @override
  bool get isOpen => _file != null;

  @override
  String? get filePath => _filePath;

  @override
  Future<void> start({
    required int sampleRate,
    required int channels,
    String? directoryPath,
  }) async {
    if (_file != null || _filePath != null) {
      throw StateError('A recording writer can only be started once.');
    }
    if (sampleRate < 8000 || sampleRate > 384000) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'Only mono or stereo is supported.');
    }

    _sampleRate = sampleRate;
    _channels = channels;
    final directory = Directory(
      directoryPath ?? _requestedDirectoryPath ?? _defaultRecordingDirectory(),
    );
    await directory.create(recursive: true);

    final file = await _createUniqueFile(directory);
    _file = await file.open(mode: FileMode.write);
    _filePath = file.path;
    await _file!.writeFrom(_header(dataBytes: 0));
    await _file!.flush();
  }

  @override
  Future<void> append(Float32List interleavedSamples) async {
    final file = _file;
    if (file == null || _finished) {
      throw StateError('No active recording file is open.');
    }
    if (interleavedSamples.isEmpty) return;
    if (interleavedSamples.length % _channels != 0) {
      throw ArgumentError(
        'The sample count must be divisible by the recording channel count.',
      );
    }

    final addedBytes = interleavedSamples.length * _bytesPerSample;
    if (addedBytes > _maxDataBytes - _dataBytes) {
      throw const AudioRecordingUnavailable(
        'The WAV recording reached its 4 GiB size limit. Stop and save this take.',
      );
    }

    final output = Uint8List(addedBytes);
    for (var index = 0; index < interleavedSamples.length; index++) {
      final sample = interleavedSamples[index];
      if (!sample.isFinite) {
        throw ArgumentError('Audio samples must be finite.');
      }
      final bounded = sample.clamp(-1.0, 1.0);
      final quantized = bounded <= -1.0
          ? -8388608
          : (bounded * 8388607.0).round();
      final offset = index * _bytesPerSample;
      output[offset] = quantized & 0xFF;
      output[offset + 1] = (quantized >> 8) & 0xFF;
      output[offset + 2] = (quantized >> 16) & 0xFF;
    }

    await file.writeFrom(output);
    _dataBytes += addedBytes;
  }

  @override
  Future<String> finish() async {
    if (_finished) {
      final path = _filePath;
      if (path == null) throw StateError('No recording file was created.');
      return path;
    }
    final file = _file;
    final path = _filePath;
    if (file == null || path == null) {
      throw StateError('No recording file is open.');
    }

    try {
      await file.setPosition(0);
      await file.writeFrom(_header(dataBytes: _dataBytes));
      await file.flush();
    } finally {
      await file.close();
      _file = null;
      _finished = true;
    }
    return path;
  }

  @override
  Future<void> discard() async {
    final file = _file;
    _file = null;
    if (file != null) {
      await file.close();
    }
    final path = _filePath;
    _filePath = null;
    _finished = true;
    if (path != null) {
      final recording = File(path);
      if (await recording.exists()) {
        await recording.delete();
      }
    }
  }

  Uint8List _header({required int dataBytes}) {
    final header = ByteData(44);
    final blockAlign = _channels * _bytesPerSample;
    header.setUint32(0, 0x46464952, Endian.little); // RIFF
    header.setUint32(4, 36 + dataBytes, Endian.little);
    header.setUint32(8, 0x45564157, Endian.little); // WAVE
    header.setUint32(12, 0x20746D66, Endian.little); // fmt 
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, _channels, Endian.little);
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, _sampleRate * blockAlign, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, _bitsPerSample, Endian.little);
    header.setUint32(36, 0x61746164, Endian.little); // data
    header.setUint32(40, dataBytes, Endian.little);
    return header.buffer.asUint8List();
  }

  Future<File> _createUniqueFile(Directory directory) async {
    final now = DateTime.now();
    final stamp = [
      now.year.toString().padLeft(4, '0'),
      now.month.toString().padLeft(2, '0'),
      now.day.toString().padLeft(2, '0'),
      '_',
      now.hour.toString().padLeft(2, '0'),
      now.minute.toString().padLeft(2, '0'),
      now.second.toString().padLeft(2, '0'),
    ].join();
    for (var suffix = 0; suffix < 10000; suffix++) {
      final ending = suffix == 0 ? '' : '_${suffix.toString().padLeft(3, '0')}';
      final file = File(
        '${directory.path}${Platform.pathSeparator}AuraVoice_$stamp$ending.wav',
      );
      if (!await file.exists()) return file;
    }
    throw const AudioRecordingUnavailable(
      'Could not create a unique recording file name.',
    );
  }

  String _defaultRecordingDirectory() {
    final environment = Platform.environment;
    final home = environment['USERPROFILE'] ??
        environment['HOME'] ??
        Directory.current.path;
    return '$home${Platform.pathSeparator}Documents'
        '${Platform.pathSeparator}Aura Voice Studio'
        '${Platform.pathSeparator}Recordings';
  }
}
