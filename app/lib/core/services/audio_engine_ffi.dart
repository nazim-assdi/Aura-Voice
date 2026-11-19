import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../features/session/models/audio_session.dart';
import 'audio_engine_contract.dart';

AudioEngineService createAudioEngineService() => FfiAudioEngineService();

class FfiAudioEngineService implements AudioEngineService {
  FfiAudioEngineService() : _api = _tryOpen();

  final _NativeApi? _api;

  @override
  bool get isAvailable => _api != null;

  @override
  Future<List<AudioInputDevice>> listInputDevices() async {
    final api = _api;
    if (api == null) {
      throw const AudioEngineUnavailable(
        'Native Aura audio library is not available on this platform.',
      );
    }
    final pointer = api.listInputDevices();
    if (pointer == nullptr) {
      throw AudioEngineUnavailable(api.lastError());
    }
    try {
      final decoded = jsonDecode(pointer.toDartString()) as List<dynamic>;
      return decoded
          .map((item) => Map<String, dynamic>.from(item as Map))
          .map(
            (item) => AudioInputDevice(
              id: item['id'] as String,
              name: item['name'] as String,
              isDefault: item['isDefault'] as bool? ?? false,
              channels: item['channels'] as int? ?? 0,
              sampleRate: item['sampleRate'] as int? ?? 0,
            ),
          )
          .toList(growable: false);
    } finally {
      api.freeString(pointer);
    }
  }

  @override
  Future<AudioCaptureSession> startCapture({
    String? deviceId,
    int bufferMilliseconds = 1000,
  }) async {
    final api = _api;
    if (api == null) {
      throw const AudioEngineUnavailable(
        'Native Aura audio library is not available on this platform.',
      );
    }
    final nativeId = deviceId?.toNativeUtf8() ?? nullptr;
    final sampleRate = calloc<Uint32>();
    final channels = calloc<Uint16>();
    try {
      final handle = api.captureStart(
        nativeId,
        bufferMilliseconds,
        sampleRate,
        channels,
      );
      if (handle == nullptr) {
        throw AudioEngineUnavailable(api.lastError());
      }
      return FfiAudioCaptureSession._(
        api: api,
        handle: handle,
        sampleRate: sampleRate.value,
        channels: channels.value,
      );
    } finally {
      if (nativeId != nullptr) {
        calloc.free(nativeId);
      }
      calloc.free(sampleRate);
      calloc.free(channels);
    }
  }

  @override
  Future<AudioPlaybackSession> startPlayback({
    required Uint8List wavBytes,
  }) async {
    final api = _api;
    if (api == null) {
      throw const AudioEngineUnavailable(
        'Native Aura audio library is not available on this platform.',
      );
    }
    if (wavBytes.length < 44 || wavBytes.length > 268435456) {
      throw ArgumentError.value(
        wavBytes.length,
        'wavBytes',
        'WAV must be between 44 bytes and 256 MiB.',
      );
    }
    final data = calloc<Uint8>(wavBytes.length);
    final sampleRate = calloc<Uint32>();
    final totalFrames = calloc<Uint64>();
    try {
      data.asTypedList(wavBytes.length).setAll(0, wavBytes);
      final handle = api.playbackStartWav(
        data,
        wavBytes.length,
        sampleRate,
        totalFrames,
      );
      if (handle == nullptr) {
        throw AudioEngineUnavailable(api.lastError());
      }
      return FfiAudioPlaybackSession._(
        api: api,
        handle: handle,
        sampleRate: sampleRate.value,
        totalFrames: totalFrames.value,
      );
    } finally {
      calloc.free(data);
      calloc.free(sampleRate);
      calloc.free(totalFrames);
    }
  }


  @override
  Future<AudioPlaybackSession> startRealtimePlayback({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
  }) async {
    final api = _api;
    if (api == null) {
      throw const AudioEngineUnavailable(
        'Native Aura audio library was not found beside the application.',
      );
    }
    var totalBytes = 0;
    const maximumRealtimeInputBytes = 536870912;
    final workerAssets = <String, Uint8List>{};
    for (final entry in assetWavs.entries) {
      if (entry.value.length > maximumRealtimeInputBytes - totalBytes) {
        throw const AudioEngineUnavailable(
          'Realtime playback is limited to 512 MiB of source WAV data per session.',
        );
      }
      totalBytes += entry.value.length;
      // Isolate.run transfers the payload to its worker. Keep one reference
      // here rather than allocating a second full WAV copy before transfer.
      workerAssets[entry.key] = entry.value;
    }
    final sessionJson = session.toJson();
    final result = await Isolate.run(
      () => _startRealtimePlaybackInWorker(sessionJson, workerAssets),
    );
    return FfiAudioPlaybackSession._(
      api: api,
      handle: Pointer<Void>.fromAddress(result['handleAddress']!),
      sampleRate: result['sampleRate']!,
      totalFrames: result['totalFrames']!,
    );
  }

  @override
  Future<AudioRenderResult> renderSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
    int? bitDepth,
  }) async {
    if (_api == null) {
      throw const AudioEngineUnavailable(
        'Native Aura audio library was not found beside the application.',
      );
    }

    final sessionJson = session.toJson();
    final copiedAssets = <String, Uint8List>{
      for (final entry in assetWavs.entries)
        entry.key: Uint8List.fromList(entry.value),
    };
    return Isolate.run(
      () => _renderInWorker(
        sessionJson,
        copiedAssets,
        bitDepth ?? session.bitDepth,
      ),
    );
  }
}

_NativeApi? _tryOpen() {
  try {
    return _NativeApi.open();
  } catch (_) {
    return null;
  }
}

AudioRenderResult _renderInWorker(
  Map<String, Object> sessionJson,
  Map<String, Uint8List> assetWavs,
  int bitDepth,
) {
  final api = _NativeApi.open();
  final session = AudioSession.fromJson(
    Map<String, dynamic>.from(sessionJson),
  );
  final handle = api.create(session.sampleRate, session.channels);
  if (handle == nullptr) {
    throw AudioEngineUnavailable(api.lastError());
  }

  try {
    for (final entry in assetWavs.entries) {
      final id = entry.key.toNativeUtf8();
      final data = calloc<Uint8>(entry.value.length);
      try {
        data.asTypedList(entry.value.length).setAll(0, entry.value);
        final status = api.addWavAsset(
          handle,
          id,
          data,
          entry.value.length,
        );
        _checkStatus(api, status);
      } finally {
        calloc.free(data);
        calloc.free(id);
      }
    }

    for (final track in session.tracks) {
      final id = track.id.toNativeUtf8();
      try {
        _checkStatus(
          api,
          api.addTrack(
            handle,
            id,
            track.gain,
            track.pan,
            track.muted ? 1 : 0,
            track.solo ? 1 : 0,
          ),
        );
        _checkStatus(
          api,
          api.setTrackDsp(
            handle,
            id,
            track.highPassHz,
            track.compressorThreshold,
            track.compressorRatio,
          ),
        );
      } finally {
        calloc.free(id);
      }

      for (final clip in track.clips) {
        final trackId = track.id.toNativeUtf8();
        final clipId = clip.id.toNativeUtf8();
        final assetId = clip.mediaId.toNativeUtf8();
        try {
          _checkStatus(
            api,
            api.addClip(
              handle,
              trackId,
              clipId,
              assetId,
              clip.startFrame,
              clip.sourceStartFrame,
              clip.durationFrames,
              clip.gain,
              clip.pan,
              clip.muted ? 1 : 0,
              clip.fadeInFrames,
              clip.fadeOutFrames,
            ),
          );
        } finally {
          calloc.free(trackId);
          calloc.free(clipId);
          calloc.free(assetId);
        }
      }
    }

    final outData = calloc<Pointer<Uint8>>();
    final outLength = calloc<IntPtr>();
    final outPeak = calloc<Float>();
    final outClipped = calloc<IntPtr>();
    try {
      final status = api.renderWav(
        handle,
        bitDepth,
        outData,
        outLength,
        outPeak,
        outClipped,
      );
      _checkStatus(api, status);
      if (outData.value == nullptr || outLength.value < 44) {
        throw const AudioEngineUnavailable(
          'The native renderer returned an invalid WAV buffer.',
        );
      }
      final bytes = Uint8List.fromList(
        outData.value.asTypedList(outLength.value),
      );
      return AudioRenderResult(
        wavBytes: bytes,
        samplePeak: outPeak.value,
        clippedSamples: outClipped.value,
      );
    } finally {
      if (outData.value != nullptr) {
        api.freeBuffer(outData.value, outLength.value);
      }
      calloc.free(outData);
      calloc.free(outLength);
      calloc.free(outPeak);
      calloc.free(outClipped);
    }
  } finally {
    api.destroy(handle);
  }
}



/// Prepares a native session and starts its callback-driven output stream on
/// a worker isolate so WAV decoding and graph preparation do not block Flutter.
Map<String, int> _startRealtimePlaybackInWorker(
  Map<String, Object> sessionJson,
  Map<String, Uint8List> assetWavs,
) {
  final api = _NativeApi.open();
  final session = AudioSession.fromJson(
    Map<String, dynamic>.from(sessionJson),
  );
  final handle = api.create(session.sampleRate, session.channels);
  if (handle == nullptr) {
    throw AudioEngineUnavailable(api.lastError());
  }

  try {
    for (final entry in assetWavs.entries) {
      final id = entry.key.toNativeUtf8();
      final data = calloc<Uint8>(entry.value.length);
      try {
        data.asTypedList(entry.value.length).setAll(0, entry.value);
        _checkStatus(
          api,
          api.addWavAsset(handle, id, data, entry.value.length),
        );
      } finally {
        calloc.free(data);
        calloc.free(id);
      }
    }

    for (final track in session.tracks) {
      final trackId = track.id.toNativeUtf8();
      try {
        _checkStatus(
          api,
          api.addTrack(
            handle,
            trackId,
            track.gain,
            track.pan,
            track.muted ? 1 : 0,
            track.solo ? 1 : 0,
          ),
        );
        _checkStatus(
          api,
          api.setTrackDsp(
            handle,
            trackId,
            track.highPassHz,
            track.compressorThreshold,
            track.compressorRatio,
          ),
        );
      } finally {
        calloc.free(trackId);
      }

      for (final clip in track.clips) {
        final nativeTrackId = track.id.toNativeUtf8();
        final clipId = clip.id.toNativeUtf8();
        final assetId = clip.mediaId.toNativeUtf8();
        try {
          _checkStatus(
            api,
            api.addClip(
              handle,
              nativeTrackId,
              clipId,
              assetId,
              clip.startFrame,
              clip.sourceStartFrame,
              clip.durationFrames,
              clip.gain,
              clip.pan,
              clip.muted ? 1 : 0,
              clip.fadeInFrames,
              clip.fadeOutFrames,
            ),
          );
        } finally {
          calloc.free(nativeTrackId);
          calloc.free(clipId);
          calloc.free(assetId);
        }
      }
    }

    final totalFrames = calloc<Uint64>();
    try {
      final playback = api.realtimePlaybackStart(handle, totalFrames);
      if (playback == nullptr) {
        throw AudioEngineUnavailable(api.lastError());
      }
      return {
        'handleAddress': playback.address,
        'sampleRate': session.sampleRate,
        'totalFrames': totalFrames.value,
      };
    } finally {
      calloc.free(totalFrames);
    }
  } finally {
    // The realtime playback handle owns an immutable Arc-backed snapshot, so
    // the temporary session builder can be released immediately.
    api.destroy(handle);
  }
}

int _replaceRealtimeSessionInWorker(
  int playbackAddress,
  Map<String, Object> sessionJson,
  Map<String, Uint8List> assetWavs,
) {
  final api = _NativeApi.open();
  final session = AudioSession.fromJson(
    Map<String, dynamic>.from(sessionJson),
  );
  final builder = api.create(session.sampleRate, session.channels);
  if (builder == nullptr) {
    throw AudioEngineUnavailable(api.lastError());
  }

  try {
    for (final entry in assetWavs.entries) {
      final id = entry.key.toNativeUtf8();
      final data = calloc<Uint8>(entry.value.length);
      try {
        data.asTypedList(entry.value.length).setAll(0, entry.value);
        _checkStatus(
          api,
          api.addWavAsset(builder, id, data, entry.value.length),
        );
      } finally {
        calloc.free(data);
        calloc.free(id);
      }
    }

    for (final track in session.tracks) {
      final trackId = track.id.toNativeUtf8();
      try {
        _checkStatus(
          api,
          api.addTrack(
            builder,
            trackId,
            track.gain,
            track.pan,
            track.muted ? 1 : 0,
            track.solo ? 1 : 0,
          ),
        );
        _checkStatus(
          api,
          api.setTrackDsp(
            builder,
            trackId,
            track.highPassHz,
            track.compressorThreshold,
            track.compressorRatio,
          ),
        );
      } finally {
        calloc.free(trackId);
      }

      for (final clip in track.clips) {
        final nativeTrackId = track.id.toNativeUtf8();
        final clipId = clip.id.toNativeUtf8();
        final assetId = clip.mediaId.toNativeUtf8();
        try {
          _checkStatus(
            api,
            api.addClip(
              builder,
              nativeTrackId,
              clipId,
              assetId,
              clip.startFrame,
              clip.sourceStartFrame,
              clip.durationFrames,
              clip.gain,
              clip.pan,
              clip.muted ? 1 : 0,
              clip.fadeInFrames,
              clip.fadeOutFrames,
            ),
          );
        } finally {
          calloc.free(nativeTrackId);
          calloc.free(clipId);
          calloc.free(assetId);
        }
      }
    }

    final totalFrames = calloc<Uint64>();
    try {
      _checkStatus(
        api,
        api.playbackReplaceSession(
          Pointer<Void>.fromAddress(playbackAddress),
          builder,
          totalFrames,
        ),
      );
      return totalFrames.value;
    } finally {
      calloc.free(totalFrames);
    }
  } finally {
    api.destroy(builder);
  }
}

void _checkStatus(_NativeApi api, int status) {
  if (status != 0) {
    throw AudioEngineUnavailable(api.lastError());
  }
}

class FfiAudioPlaybackSession implements AudioPlaybackSession {
  FfiAudioPlaybackSession._({
    required _NativeApi api,
    required Pointer<Void> handle,
    required this.sampleRate,
    required int totalFrames,
  })  : _api = api,
        _handle = handle,
        _totalFrames = totalFrames;

  final _NativeApi _api;
  Pointer<Void> _handle;
  bool _stopped = false;
  bool _paused = false;
  int _totalFrames;
  Future<void> _replaceQueue = Future<void>.value();
  Future<void>? _stopFuture;
  bool _stopping = false;

  @override
  final int sampleRate;

  @override
  int get totalFrames => _totalFrames;

  @override
  int get positionFrames =>
      _stopped ? totalFrames : _api.playbackPositionFrames(_handle);

  @override
  bool get isComplete =>
      _stopped || _api.playbackStatus(_handle) == 1;

  @override
  bool get hasError =>
      !_stopped && _api.playbackStatus(_handle) == 2;

  @override
  bool get isPaused => _paused;

  void _checkActive() {
    if (_stopped || _stopping) {
      throw const AudioEngineUnavailable('The playback stream is stopping or stopped.');
    }
  }

  @override
  Future<void> pause() async {
    _checkActive();
    final status = _api.playbackPause(_handle);
    if (status != 0) throw AudioEngineUnavailable(_api.lastError());
    _paused = true;
  }

  @override
  Future<void> resume() async {
    _checkActive();
    final status = _api.playbackResume(_handle);
    if (status != 0) throw AudioEngineUnavailable(_api.lastError());
    _paused = false;
  }

  @override
  Future<void> seek(int frame) async {
    _checkActive();
    if (frame < 0 || frame > totalFrames) {
      throw RangeError.range(frame, 0, totalFrames, 'frame');
    }
    final status = _api.playbackSeek(_handle, frame);
    if (status != 0) throw AudioEngineUnavailable(_api.lastError());
  }

  @override
  Future<void> setLoopRange({
    required int startFrame,
    required int endFrame,
    required bool enabled,
  }) async {
    _checkActive();
    if (enabled &&
        (startFrame < 0 ||
            startFrame >= endFrame ||
            endFrame > totalFrames)) {
      throw RangeError('Loop range must be a non-empty range inside playback.');
    }
    final status = _api.playbackSetLoop(
      _handle,
      startFrame,
      endFrame,
      enabled ? 1 : 0,
    );
    if (status != 0) throw AudioEngineUnavailable(_api.lastError());
  }

  @override
  Future<void> replaceSession({
    required AudioSession session,
    required Map<String, Uint8List> assetWavs,
  }) {
    _checkActive();

    // Serialize graph publications, and keep the native playback pointer
    // alive until every queued worker-isolate publication has returned.
    final previous = _replaceQueue;
    final completion = Completer<void>();
    _replaceQueue = completion.future;

    return () async {
      try {
        await previous;
        _checkActive();
        var totalBytes = 0;
        const maximumRealtimeInputBytes = 536870912;
        final workerAssets = <String, Uint8List>{};
        for (final entry in assetWavs.entries) {
          if (entry.value.length > maximumRealtimeInputBytes - totalBytes) {
            throw const AudioEngineUnavailable(
              'Realtime graph updates are limited to 512 MiB of source WAV data per session.',
            );
          }
          totalBytes += entry.value.length;
          workerAssets[entry.key] = entry.value;
        }
        final sessionJson = session.toJson();
        final nextTotalFrames = await Isolate.run(
          () => _replaceRealtimeSessionInWorker(
            _handle.address,
            sessionJson,
            workerAssets,
          ),
        );
        _totalFrames = nextTotalFrames;
      } finally {
        completion.complete();
      }
    }();
  }

  @override
  Future<void> stop() => _stopFuture ??= _stopAfterPendingGraphUpdates();

  Future<void> _stopAfterPendingGraphUpdates() async {
    if (_stopped) return;
    _stopping = true;
    await _replaceQueue;
    if (!_stopped) {
      _api.playbackStop(_handle);
      _handle = nullptr;
      _paused = false;
      _stopped = true;
    }
  }

}

class FfiAudioCaptureSession implements AudioCaptureSession {
  FfiAudioCaptureSession._({
    required _NativeApi api,
    required Pointer<Void> handle,
    required this.sampleRate,
    required this.channels,
  })  : _api = api,
        _handle = handle;

  final _NativeApi _api;
  Pointer<Void> _handle;
  bool _stopped = false;

  @override
  final int sampleRate;

  @override
  final int channels;

  @override
  int get droppedFrames =>
      _stopped ? 0 : _api.captureDroppedFrames(_handle);

  @override
  bool get hasError => _stopped || _api.captureStatus(_handle) != 0;

  @override
  Future<void> pause() async {
    if (_stopped) return;
    final status = _api.capturePause(_handle);
    if (status != 0) {
      throw AudioEngineUnavailable(_api.lastError());
    }
  }

  @override
  Future<Float32List> readFrames({int maxFrames = 2048}) async {
    if (_stopped) {
      throw const AudioEngineUnavailable('The microphone capture is stopped.');
    }
    if (maxFrames <= 0 || maxFrames > 65536) {
      throw ArgumentError.value(
        maxFrames,
        'maxFrames',
        'Must be between 1 and 65536.',
      );
    }
    final sampleCount = maxFrames * channels;
    final output = calloc<Float>(sampleCount);
    try {
      final frames = _api.captureRead(_handle, output, maxFrames);
      if (frames == 0) {
        return Float32List(0);
      }
      return Float32List.fromList(
        output.asTypedList(frames * channels),
      );
    } finally {
      calloc.free(output);
    }
  }

  @override
  Future<void> stop() async {
    if (!_stopped) {
      _api.captureStop(_handle);
      _handle = nullptr;
      _stopped = true;
    }
  }
}

class _NativeApi {
  _NativeApi(DynamicLibrary library)
      : _listInputDevices =
            library.lookupFunction<_ListInputDevicesNative, _ListInputDevicesDart>(
          'aura_audio_input_devices_json',
        ),
        _freeString =
            library.lookupFunction<_FreeStringNative, _FreeStringDart>(
          'aura_audio_string_free',
        ),
        _captureStart =
            library.lookupFunction<_CaptureStartNative, _CaptureStartDart>(
          'aura_audio_capture_start',
        ),
        _realtimePlaybackStart = library.lookupFunction<
            _RealtimePlaybackStartNative,
            _RealtimePlaybackStartDart>(
          'aura_engine_realtime_playback_start',
        ),
        _playbackStartWav = library.lookupFunction<
            _PlaybackStartWavNative,
            _PlaybackStartWavDart>(
          'aura_audio_playback_start_wav',
        ),
        _playbackReplaceSession = library.lookupFunction<
            _PlaybackReplaceSessionNative,
            _PlaybackReplaceSessionDart>(
          'aura_audio_playback_replace_session',
        ),
        _playbackPositionFrames = library.lookupFunction<
            _PlaybackPositionFramesNative,
            _PlaybackPositionFramesDart>(
          'aura_audio_playback_position_frames',
        ),
        _playbackStatus = library.lookupFunction<
            _PlaybackStatusNative,
            _PlaybackStatusDart>(
          'aura_audio_playback_status',
        ),
        _playbackPause = library.lookupFunction<
            _PlaybackPauseNative,
            _PlaybackPauseDart>(
          'aura_audio_playback_pause',
        ),
        _playbackResume = library.lookupFunction<
            _PlaybackResumeNative,
            _PlaybackResumeDart>(
          'aura_audio_playback_resume',
        ),
        _playbackSeek = library.lookupFunction<
            _PlaybackSeekNative,
            _PlaybackSeekDart>(
          'aura_audio_playback_seek',
        ),
        _playbackSetLoop = library.lookupFunction<
            _PlaybackSetLoopNative,
            _PlaybackSetLoopDart>(
          'aura_audio_playback_set_loop',
        ),
        _playbackStop =
            library.lookupFunction<_PlaybackStopNative, _PlaybackStopDart>(
          'aura_audio_playback_stop',
        ),
        _capturePause =
            library.lookupFunction<_CapturePauseNative, _CapturePauseDart>(
          'aura_audio_capture_pause',
        ),
        _captureRead =
            library.lookupFunction<_CaptureReadNative, _CaptureReadDart>(
          'aura_audio_capture_read',
        ),
        _captureDroppedFrames = library.lookupFunction<
            _CaptureDroppedFramesNative,
            _CaptureDroppedFramesDart>(
          'aura_audio_capture_dropped_frames',
        ),
        _captureStatus =
            library.lookupFunction<_CaptureStatusNative, _CaptureStatusDart>(
          'aura_audio_capture_status',
        ),
        _captureStop =
            library.lookupFunction<_CaptureStopNative, _CaptureStopDart>(
          'aura_audio_capture_stop',
        ),
        _abiVersion = library.lookupFunction<_AbiNative, _AbiDart>(
          'aura_engine_abi_version',
        ),
        _create = library.lookupFunction<_CreateNative, _CreateDart>(
          'aura_engine_create',
        ),
        _destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
          'aura_engine_destroy',
        ),
        _addWavAsset =
            library.lookupFunction<_AddWavAssetNative, _AddWavAssetDart>(
          'aura_engine_add_wav_asset',
        ),
        _addTrack = library.lookupFunction<_AddTrackNative, _AddTrackDart>(
          'aura_engine_add_track',
        ),
        _setTrackDsp =
            library.lookupFunction<_SetTrackDspNative, _SetTrackDspDart>(
          'aura_engine_set_track_dsp',
        ),
        _addClip = library.lookupFunction<_AddClipNative, _AddClipDart>(
          'aura_engine_add_clip',
        ),
        _renderWav =
            library.lookupFunction<_RenderWavNative, _RenderWavDart>(
          'aura_engine_render_wav',
        ),
        _freeBuffer =
            library.lookupFunction<_FreeBufferNative, _FreeBufferDart>(
          'aura_engine_free_buffer',
        ),
        _lastError =
            library.lookupFunction<_LastErrorNative, _LastErrorDart>(
          'aura_engine_last_error',
        ) {
    final abi = _abiVersion();
    if (abi != 4) {
      throw AudioEngineUnavailable(
        'Native audio ABI mismatch: expected 4, found $abi.',
      );
    }
  }

  final Pointer<Utf8> Function() _listInputDevices;
  final void Function(Pointer<Utf8>) _freeString;
  final Pointer<Void> Function(
    Pointer<Utf8>,
    int,
    Pointer<Uint32>,
    Pointer<Uint16>,
  ) _captureStart;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>)
      _realtimePlaybackStart;
  final Pointer<Void> Function(
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<Uint64>,
  ) _playbackStartWav;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Uint64>)
      _playbackReplaceSession;
  final int Function(Pointer<Void>) _playbackPositionFrames;
  final int Function(Pointer<Void>) _playbackStatus;
  final int Function(Pointer<Void>) _playbackPause;
  final int Function(Pointer<Void>) _playbackResume;
  final int Function(Pointer<Void>, int) _playbackSeek;
  final int Function(Pointer<Void>, int, int, int) _playbackSetLoop;
  final void Function(Pointer<Void>) _playbackStop;
  final int Function(Pointer<Void>) _capturePause;
  final int Function(Pointer<Void>, Pointer<Float>, int) _captureRead;
  final int Function(Pointer<Void>) _captureDroppedFrames;
  final int Function(Pointer<Void>) _captureStatus;
  final void Function(Pointer<Void>) _captureStop;

  final int Function() _abiVersion;
  final Pointer<Void> Function(int, int) _create;
  final void Function(Pointer<Void>) _destroy;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Uint8>,
    int,
  ) _addWavAsset;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    double,
    double,
    int,
    int,
  ) _addTrack;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    double,
    double,
    double,
  ) _setTrackDsp;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    int,
    int,
    double,
    double,
    int,
    int,
    int,
  ) _addClip;
  final int Function(
    Pointer<Void>,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<IntPtr>,
    Pointer<Float>,
    Pointer<IntPtr>,
  ) _renderWav;
  final void Function(Pointer<Uint8>, int) _freeBuffer;
  final Pointer<Utf8> Function() _lastError;

  Pointer<Void> realtimePlaybackStart(
    Pointer<Void> engine,
    Pointer<Uint64> totalFrames,
  ) =>
      _realtimePlaybackStart(engine, totalFrames);

  Pointer<Utf8> listInputDevices() => _listInputDevices();
  void freeString(Pointer<Utf8> value) => _freeString(value);
  Pointer<Void> captureStart(
    Pointer<Utf8> deviceId,
    int bufferMilliseconds,
    Pointer<Uint32> sampleRate,
    Pointer<Uint16> channels,
  ) =>
      _captureStart(deviceId, bufferMilliseconds, sampleRate, channels);
  Pointer<Void> playbackStartWav(
    Pointer<Uint8> bytes,
    int length,
    Pointer<Uint32> sampleRate,
    Pointer<Uint64> totalFrames,
  ) =>
      _playbackStartWav(bytes, length, sampleRate, totalFrames);
  int playbackReplaceSession(
    Pointer<Void> playback,
    Pointer<Void> builder,
    Pointer<Uint64> totalFrames,
  ) =>
      _playbackReplaceSession(playback, builder, totalFrames);

  int playbackPositionFrames(Pointer<Void> handle) =>
      _playbackPositionFrames(handle);
  int playbackStatus(Pointer<Void> handle) => _playbackStatus(handle);
  int playbackPause(Pointer<Void> handle) => _playbackPause(handle);
  int playbackResume(Pointer<Void> handle) => _playbackResume(handle);
  int playbackSeek(Pointer<Void> handle, int frame) =>
      _playbackSeek(handle, frame);
  int playbackSetLoop(
    Pointer<Void> handle,
    int startFrame,
    int endFrame,
    int enabled,
  ) =>
      _playbackSetLoop(handle, startFrame, endFrame, enabled);
  void playbackStop(Pointer<Void> handle) => _playbackStop(handle);

  int capturePause(Pointer<Void> handle) => _capturePause(handle);
  int captureRead(Pointer<Void> handle, Pointer<Float> output, int maxFrames) =>
      _captureRead(handle, output, maxFrames);
  int captureDroppedFrames(Pointer<Void> handle) =>
      _captureDroppedFrames(handle);
  int captureStatus(Pointer<Void> handle) => _captureStatus(handle);
  void captureStop(Pointer<Void> handle) => _captureStop(handle);

  Pointer<Void> create(int sampleRate, int channels) =>
      _create(sampleRate, channels);
  void destroy(Pointer<Void> handle) => _destroy(handle);

  int addWavAsset(
    Pointer<Void> handle,
    Pointer<Utf8> id,
    Pointer<Uint8> bytes,
    int length,
  ) =>
      _addWavAsset(handle, id, bytes, length);

  int addTrack(
    Pointer<Void> handle,
    Pointer<Utf8> id,
    double gain,
    double pan,
    int muted,
    int solo,
  ) =>
      _addTrack(handle, id, gain, pan, muted, solo);

  int setTrackDsp(
    Pointer<Void> handle,
    Pointer<Utf8> id,
    double highPassHz,
    double compressorThreshold,
    double compressorRatio,
  ) =>
      _setTrackDsp(
        handle,
        id,
        highPassHz,
        compressorThreshold,
        compressorRatio,
      );

  int addClip(
    Pointer<Void> handle,
    Pointer<Utf8> trackId,
    Pointer<Utf8> clipId,
    Pointer<Utf8> assetId,
    int startFrame,
    int sourceStartFrame,
    int durationFrames,
    double gain,
    double pan,
    int muted,
    int fadeInFrames,
    int fadeOutFrames,
  ) =>
      _addClip(
        handle,
        trackId,
        clipId,
        assetId,
        startFrame,
        sourceStartFrame,
        durationFrames,
        gain,
        pan,
        muted,
        fadeInFrames,
        fadeOutFrames,
      );

  int renderWav(
    Pointer<Void> handle,
    int bitDepth,
    Pointer<Pointer<Uint8>> output,
    Pointer<IntPtr> outputLength,
    Pointer<Float> peak,
    Pointer<IntPtr> clipped,
  ) =>
      _renderWav(
        handle,
        bitDepth,
        output,
        outputLength,
        peak,
        clipped,
      );

  void freeBuffer(Pointer<Uint8> bytes, int length) =>
      _freeBuffer(bytes, length);

  String lastError() {
    final pointer = _lastError();
    return pointer == nullptr ? 'Unknown native audio error.' : pointer.toDartString();
  }

  static _NativeApi open() {
    final configuredPath = const String.fromEnvironment(
      'AURA_AUDIO_ENGINE_LIBRARY',
    );
    final library = configuredPath.isNotEmpty
        ? DynamicLibrary.open(configuredPath)
        : _openPlatformLibrary();
    return _NativeApi(library);
  }
}

DynamicLibrary _openPlatformLibrary() {
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }

  final fileName = Platform.isWindows
      ? 'aura_audio_engine.dll'
      : Platform.isMacOS
          ? 'libaura_audio_engine.dylib'
          : 'libaura_audio_engine.so';
  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final separator = Platform.pathSeparator;
  final besideExecutable = '$executableDirectory$separator$fileName';
  if (File(besideExecutable).existsSync()) {
    return DynamicLibrary.open(besideExecutable);
  }
  return DynamicLibrary.open(fileName);
}

typedef _ListInputDevicesNative = Pointer<Utf8> Function();
typedef _ListInputDevicesDart = Pointer<Utf8> Function();

typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

typedef _CaptureStartNative = Pointer<Void> Function(
  Pointer<Utf8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Uint16>,
);
typedef _CaptureStartDart = Pointer<Void> Function(
  Pointer<Utf8>,
  int,
  Pointer<Uint32>,
  Pointer<Uint16>,
);

typedef _RealtimePlaybackStartNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint64>,
);
typedef _RealtimePlaybackStartDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint64>,
);

typedef _PlaybackStartWavNative = Pointer<Void> Function(
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint32>,
  Pointer<Uint64>,
);
typedef _PlaybackStartWavDart = Pointer<Void> Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Uint64>,
);

typedef _PlaybackReplaceSessionNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint64>,
);
typedef _PlaybackReplaceSessionDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint64>,
);

typedef _PlaybackPositionFramesNative = Uint64 Function(Pointer<Void>);
typedef _PlaybackPositionFramesDart = int Function(Pointer<Void>);

typedef _PlaybackStatusNative = Uint32 Function(Pointer<Void>);
typedef _PlaybackStatusDart = int Function(Pointer<Void>);

typedef _PlaybackPauseNative = Int32 Function(Pointer<Void>);
typedef _PlaybackPauseDart = int Function(Pointer<Void>);

typedef _PlaybackResumeNative = Int32 Function(Pointer<Void>);
typedef _PlaybackResumeDart = int Function(Pointer<Void>);

typedef _PlaybackSeekNative = Int32 Function(Pointer<Void>, Uint64);
typedef _PlaybackSeekDart = int Function(Pointer<Void>, int);

typedef _PlaybackSetLoopNative = Int32 Function(
  Pointer<Void>,
  Uint64,
  Uint64,
  Uint8,
);
typedef _PlaybackSetLoopDart = int Function(
  Pointer<Void>,
  int,
  int,
  int,
);

typedef _PlaybackStopNative = Void Function(Pointer<Void>);
typedef _PlaybackStopDart = void Function(Pointer<Void>);

typedef _CapturePauseNative = Int32 Function(Pointer<Void>);
typedef _CapturePauseDart = int Function(Pointer<Void>);

typedef _CaptureReadNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Float>,
  Uint32,
);
typedef _CaptureReadDart = int Function(
  Pointer<Void>,
  Pointer<Float>,
  int,
);

typedef _CaptureDroppedFramesNative = Uint64 Function(Pointer<Void>);
typedef _CaptureDroppedFramesDart = int Function(Pointer<Void>);

typedef _CaptureStatusNative = Uint32 Function(Pointer<Void>);
typedef _CaptureStatusDart = int Function(Pointer<Void>);

typedef _CaptureStopNative = Void Function(Pointer<Void>);
typedef _CaptureStopDart = void Function(Pointer<Void>);

typedef _AbiNative = Uint32 Function();
typedef _AbiDart = int Function();

typedef _CreateNative = Pointer<Void> Function(Uint32, Uint16);
typedef _CreateDart = Pointer<Void> Function(int, int);

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

typedef _AddWavAssetNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  IntPtr,
);
typedef _AddWavAssetDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
);

typedef _AddTrackNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Float,
  Float,
  Uint8,
  Uint8,
);
typedef _AddTrackDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  double,
  double,
  int,
  int,
);

typedef _SetTrackDspNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Float,
  Float,
  Float,
);
typedef _SetTrackDspDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  double,
  double,
  double,
);

typedef _AddClipNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint64,
  Uint64,
  Uint64,
  Float,
  Float,
  Uint8,
  Uint64,
  Uint64,
);
typedef _AddClipDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  double,
  double,
  int,
  int,
  int,
);

typedef _RenderWavNative = Int32 Function(
  Pointer<Void>,
  Uint16,
  Pointer<Pointer<Uint8>>,
  Pointer<IntPtr>,
  Pointer<Float>,
  Pointer<IntPtr>,
);
typedef _RenderWavDart = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<IntPtr>,
  Pointer<Float>,
  Pointer<IntPtr>,
);

typedef _FreeBufferNative = Void Function(Pointer<Uint8>, IntPtr);
typedef _FreeBufferDart = void Function(Pointer<Uint8>, int);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();
