import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_recording_io.dart';
import 'package:aura_voice_ai/core/services/audio_waveform_io.dart';
import 'package:aura_voice_ai/core/services/audio_waveform_service.dart';

void main() {
  group('FileAudioWaveformService', () {
    late Directory temporaryDirectory;
    const service = FileAudioWaveformService();

    setUp(() async {
      temporaryDirectory =
          await Directory.systemTemp.createTemp('aura-waveform-test-');
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    Future<String> createTake({
      int sampleRate = 48000,
      int channels = 1,
      required Float32List samples,
    }) async {
      final writer = FileAudioRecordingWriter(
        directoryPath: temporaryDirectory.path,
      );
      await writer.start(sampleRate: sampleRate, channels: channels);
      await writer.append(samples);
      return writer.finish();
    }

    test('derives real peaks from 24-bit mono WAV samples', () async {
      final samples = Float32List(4800);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i.isEven ? 0.1 : -0.2;
      }
      final path = await createTake(samples: samples);

      final waveform = await service.analyze(path, peakCount: 64);

      expect(waveform.sampleRate, 48000);
      expect(waveform.channels, 1);
      expect(waveform.bitsPerSample, 24);
      expect(waveform.frameCount, 4800);
      expect(waveform.duration, const Duration(milliseconds: 100));
      expect(waveform.peaks, hasLength(64));
      expect(waveform.peaks.every((peak) => peak > 0.19 && peak < 0.21), isTrue);
    });

    test('combines channels into a peak envelope', () async {
      final samples = Float32List(800);
      for (var frame = 0; frame < 400; frame++) {
        samples[frame * 2] = 0.1;
        samples[frame * 2 + 1] = -0.6;
      }
      final path = await createTake(channels: 2, samples: samples);

      final waveform = await service.analyze(path, peakCount: 32);

      expect(waveform.channels, 2);
      expect(waveform.peaks, hasLength(32));
      expect(waveform.peaks.every((peak) => peak > 0.59 && peak < 0.61), isTrue);
    });

    test('silence produces zero-height waveform buckets', () async {
      final path = await createTake(samples: Float32List(2048));

      final waveform = await service.analyze(path, peakCount: 64);

      expect(waveform.peaks, hasLength(64));
      expect(waveform.peaks.every((peak) => peak == 0), isTrue);
    });

    test('persists waveform peaks between service instances', () async {
      final path = await createTake(samples: Float32List(4096));
      final cacheDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}waveform-cache',
      );
      final firstService = FileAudioWaveformService(
        cacheDirectoryPath: cacheDirectory.path,
      );
      final first = await firstService.analyze(path, peakCount: 64);
      expect(await cacheDirectory.exists(), isTrue);

      final secondService = FileAudioWaveformService(
        cacheDirectoryPath: cacheDirectory.path,
      );
      final second = await secondService.analyze(path, peakCount: 64);

      expect(second.sampleRate, first.sampleRate);
      expect(second.frameCount, first.frameCount);
      expect(second.peaks, orderedEquals(first.peaks));
      var cacheFiles = 0;
      await for (final entity in cacheDirectory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.json')) {
          cacheFiles++;
        }
      }
      expect(cacheFiles, 1);
    });

    test('rejects invalid peak counts', () async {
      final path = await createTake(samples: Float32List(100));

      await expectLater(
        service.analyze(path, peakCount: 8),
        throwsArgumentError,
      );
    });

    test('rejects missing or corrupt WAV files', () async {
      final corrupt = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}broken.wav',
      );
      await corrupt.writeAsBytes([1, 2, 3, 4]);

      await expectLater(
        service.analyze(corrupt.path),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        service.analyze('${temporaryDirectory.path}${Platform.pathSeparator}missing.wav'),
        throwsA(isA<AudioWaveformUnavailable>()),
      );
    });
  });
}
