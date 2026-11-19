import 'audio_waveform_stub.dart'
    if (dart.library.io) 'audio_waveform_io.dart' as platform;

import 'audio_waveform_contract.dart';

export 'audio_waveform_contract.dart';

AudioWaveformService createAudioWaveformService() =>
    platform.createAudioWaveformService();
