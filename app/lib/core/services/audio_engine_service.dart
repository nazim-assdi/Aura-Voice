import 'audio_engine_stub.dart'
    if (dart.library.ffi) 'audio_engine_ffi.dart' as platform;

import 'audio_engine_contract.dart';

export 'audio_engine_contract.dart';

/// Creates the platform implementation without making web depend on dart:ffi.
AudioEngineService createAudioEngineService() =>
    platform.createAudioEngineService();
