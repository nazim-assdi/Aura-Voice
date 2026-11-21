import 'dart:typed_data';

import 'audio_engine_contract.dart';
import '../../features/session/models/audio_session.dart';

AudioEngineService createAudioEngineService() =>
    const UnavailableAudioEngineService();

class UnavailableAudioEngineService implements AudioEngineService {
  const UnavailableAudioEngineService();

  @override
  bool get isAvailable => false;

  @override
  Future<AudioRenderResult> renderSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    int? bitDepth,
  }) async {
    throw const AudioEngineUnavailable(
      'The native Aura audio library is not installed for this platform yet.',
    );
  }

  @override
  Future<List<AudioInputDevice>> listInputDevices() async {
    throw const AudioEngineUnavailable(
      'Microphone device access is not available on this platform.',
    );
  }

  @override
  Future<List<AudioOutputDevice>> listOutputDevices() async {
    throw const AudioEngineUnavailable(
      'Audio output device access is not available on this platform.',
    );
  }

  @override
  Future<AudioPlaybackSession> startPlayback({
    required Uint8List wavBytes,
  }) async {
    throw const AudioEngineUnavailable(
      'Audio output playback is not available on this platform.',
    );
  }

  @override
  Future<AudioPlaybackSession> startRealtimePlayback({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    String? outputDeviceId,
  }) async {
    throw const AudioEngineUnavailable(
      'Realtime multitrack playback is not available on this platform.',
    );
  }

  @override
  Future<AudioMonitorSession> startMonitor({
    String? inputDeviceId,
    String? outputDeviceId,
    int bufferMilliseconds = 30,
    double gain = 1.0,
  }) async {
    throw const AudioEngineUnavailable(
      'Live microphone monitoring is not available on this platform.',
    );
  }

  @override
  Future<AudioCaptureSession> startCapture({
    String? deviceId,
    int bufferMilliseconds = 1000,
  }) async {
    throw const AudioEngineUnavailable(
      'Microphone capture is not available on this platform.',
    );
  }
}
