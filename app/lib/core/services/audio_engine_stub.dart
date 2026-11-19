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
  }) {
    throw const AudioEngineUnavailable(
      'The native Aura audio library is not installed for this platform yet.',
    );
  }
}
