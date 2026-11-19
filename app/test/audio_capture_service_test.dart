import 'package:flutter_test/flutter_test.dart';
import 'package:aura_voice_ai/core/services/audio_engine_contract.dart';
import 'package:aura_voice_ai/core/services/audio_engine_stub.dart';
import 'package:aura_voice_ai/features/session/models/audio_session.dart';

void main() {
  group('UnavailableAudioEngineService', () {
    const service = UnavailableAudioEngineService();
    const session = AudioSession(
      id: 'test-session',
      title: 'Test',
      sampleRate: 48000,
      channels: 1,
      bitDepth: 16,
    );

    test('reports native audio as unavailable', () {
      expect(service.isAvailable, isFalse);
    });

    test('explains that input enumeration is unavailable', () async {
      await expectLater(
        service.listInputDevices(),
        throwsA(isA<AudioEngineUnavailable>()),
      );
    });

    test('does not pretend to start a microphone stream', () async {
      await expectLater(
        service.startCapture(),
        throwsA(isA<AudioEngineUnavailable>()),
      );
    });

    test('does not pretend to render an audio session', () async {
      await expectLater(
        service.renderSession(session: session, assetWavs: const {}),
        throwsA(isA<AudioEngineUnavailable>()),
      );
    });
  });
}
