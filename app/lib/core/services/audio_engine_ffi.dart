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

void _checkStatus(_NativeApi api, int status) {
  if (status != 0) {
    throw AudioEngineUnavailable(api.lastError());
  }
}

class _NativeApi {
  _NativeApi(DynamicLibrary library)
      : _abiVersion = library.lookupFunction<_AbiNative, _AbiDart>(
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
    if (abi != 1) {
      throw AudioEngineUnavailable(
        'Native audio ABI mismatch: expected 1, found $abi.',
      );
    }
  }

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
