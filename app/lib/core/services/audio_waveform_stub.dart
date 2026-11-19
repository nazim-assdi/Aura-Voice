import 'audio_waveform_contract.dart';

AudioWaveformService createAudioWaveformService() =>
    const UnavailableAudioWaveformService();

class UnavailableAudioWaveformService implements AudioWaveformService {
  const UnavailableAudioWaveformService();

  @override
  Future<AudioWaveformData> analyze(
    String path, {
    int peakCount = 320,
  }) async {
    throw const AudioWaveformUnavailable(
      'Local WAV waveform analysis is not available on this platform.',
    );
  }
}
