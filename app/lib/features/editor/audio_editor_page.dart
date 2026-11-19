import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/services/audio_engine_service.dart';
import '../../core/services/audio_file_service.dart';
import '../../core/services/audio_library_service.dart';
import '../../core/services/audio_project_service.dart';
import '../../core/services/audio_waveform_service.dart';
import '../../core/theme/aura_theme.dart';
import '../session/models/audio_session.dart';

enum _ClipDragMode { move, trimStart, trimEnd }

class AudioEditorPage extends StatefulWidget {
  const AudioEditorPage({
    this.initialRecording,
    this.initialSession,
    this.initialProjectPath,
    super.key,
  }) : assert(
          (initialRecording == null) != (initialSession == null),
          'Provide either an initial recording or an existing session.',
        );

  final AudioLibraryRecording? initialRecording;
  final AudioSession? initialSession;
  final String? initialProjectPath;

  @override
  State<AudioEditorPage> createState() => _AudioEditorPageState();
}

class _AudioEditorPageState extends State<AudioEditorPage> {
  late AudioSession _session;
  late final AudioEngineService _engine;
  late final AudioLibraryService _library;
  late final AudioProjectStore _projects;
  late final AudioWaveformService _waveforms;
  Map<String, AudioWaveformData> _waveformCache = {};

  String? _selectedTrackId;
  String? _selectedClipId;
  String? _dragTrackId;
  String? _dragClipId;
  double? _lastDragX;
  String? _projectPath;
  String? _message;
  AudioPlaybackSession? _playback;
  Timer? _playbackTimer;
  int _playbackPosition = 0;
  bool _saving = false;
  bool _rendering = false;
  bool _pollingPlayback = false;
  bool _transportPaused = false;
  bool _loopEnabled = false;
  int _transportTotalFrames = 0;
  int? _seekPreviewFrame;
  Timer? _autosaveTimer;
  bool _autosaving = false;
  int _editRevision = 0;
  int _autosavedRevision = -1;
  final List<AudioSession> _undoStack = [];
  final List<AudioSession> _redoStack = [];
  AudioSession? _transactionSnapshot;
  bool _transactionChanged = false;
  bool _snapEnabled = true;
  int _snapGridMilliseconds = 100;
  double _timelineZoom = 1.0;
  _ClipDragMode _dragMode = _ClipDragMode.move;
  AudioClip? _dragOriginalClip;

  @override
  void initState() {
    super.initState();
    _engine = createAudioEngineService();
    _library = createAudioLibraryService();
    _projects = createAudioProjectStore();
    _waveforms = createAudioWaveformService();

    final existingSession = widget.initialSession;
    if (existingSession != null) {
      _session = existingSession;
      _projectPath = widget.initialProjectPath;
      if (_session.tracks.isNotEmpty) {
        _selectedTrackId = _session.tracks.first.id;
        if (_session.tracks.first.clips.isNotEmpty) {
          _selectedClipId = _session.tracks.first.clips.first.id;
        }
      }
      for (final track in _session.tracks) {
        for (final clip in track.clips) {
          unawaited(_loadWaveform(clip.mediaId));
        }
      }
    } else {
      final recording = widget.initialRecording!;
      final trackId = 'track-${DateTime.now().microsecondsSinceEpoch}';
      final clip = AudioClip(
        id: 'clip-${DateTime.now().microsecondsSinceEpoch}',
        mediaId: recording.path,
        startFrame: 0,
        sourceStartFrame: 0,
        durationFrames: recording.frameCount,
      );
      _session = AudioSession(
        id: 'project-${DateTime.now().microsecondsSinceEpoch}',
        title: recording.name,
        sampleRate: recording.sampleRate,
        channels: recording.channels,
        bitDepth: 24,
        tracks: [
          AudioTrack(
            id: trackId,
            name: 'Voice 1',
            kind: AudioTrackKind.voice,
            clips: [clip],
          ),
        ],
      );
      _selectedTrackId = trackId;
      _selectedClipId = clip.id;
      unawaited(_loadWaveform(recording.path));
    }
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _autosaveTimer?.cancel();
    final playback = _playback;
    _playback = null;
    if (playback != null) unawaited(playback.stop());
    super.dispose();
  }

  AudioTrack? get _selectedTrack {
    for (final track in _session.tracks) {
      if (track.id == _selectedTrackId) return track;
    }
    return null;
  }

  AudioClip? get _selectedClip {
    for (final track in _session.tracks) {
      for (final clip in track.clips) {
        if (clip.id == _selectedClipId) return clip;
      }
    }
    return null;
  }

  int get _sessionEndFrame {
    var end = 0;
    for (final track in _session.tracks) {
      for (final clip in track.clips) {
        final clipEnd = clip.startFrame + clip.durationFrames;
        if (clipEnd > end) end = clipEnd;
      }
    }
    return end;
  }

  double get _totalSeconds =>
      math.max(10.0, _sessionEndFrame / _session.sampleRate + 2.0).toDouble();

  double get _pixelsPerSecond {
    final width = _timelineWidth;
    return width / _totalSeconds;
  }

  double get _timelineWidth =>
      math.max(240.0, _totalSeconds * 76.0 * _timelineZoom).toDouble();

  int _snapFrame(int frame) {
    if (!_snapEnabled) return frame;
    final gridFrames = math.max(
      1,
      _session.sampleRate * _snapGridMilliseconds ~/ 1000,
    ).toInt();
    return ((frame / gridFrames).round() * gridFrames).toInt();
  }

  void _setTimelineZoom(double value) {
    setState(() => _timelineZoom = value.clamp(0.25, 4.0).toDouble());
  }

  AudioSession _cloneSession(AudioSession session) =>
      AudioSession.fromJson(Map<String, dynamic>.from(session.toJson()));

  void _pushHistory(List<AudioSession> stack, AudioSession session) {
    if (stack.length >= 100) stack.removeAt(0);
    stack.add(session);
  }

  void _beginEditTransaction() {
    _transactionSnapshot ??= _cloneSession(_session);
    _transactionChanged = false;
  }

  void _finishEditTransaction() {
    final snapshot = _transactionSnapshot;
    if (snapshot != null && _transactionChanged) {
      _pushHistory(_undoStack, snapshot);
      _redoStack.clear();
    }
    _transactionSnapshot = null;
    _transactionChanged = false;
    if (mounted) setState(() {});
  }

  void _commitSession(AudioSession next) {
    if (_transactionSnapshot != null) {
      _transactionChanged = true;
    } else {
      _pushHistory(_undoStack, _cloneSession(_session));
      _redoStack.clear();
    }
    setState(() {
      _session = next;
      _editRevision++;
    });
    _scheduleAutosave();
  }

  void _restoreHistorySession(AudioSession restored) {
    setState(() {
      _session = restored;
      final trackExists = _session.tracks.any((track) => track.id == _selectedTrackId);
      if (!trackExists) {
        _selectedTrackId = _session.tracks.isEmpty ? null : _session.tracks.first.id;
      }
      final clipExists = _session.tracks.any(
        (track) => track.clips.any((clip) => clip.id == _selectedClipId),
      );
      if (!clipExists) _selectedClipId = null;
      _editRevision++;
    });
    _scheduleAutosave();
  }

  void _undo() {
    _finishEditTransaction();
    if (_undoStack.isEmpty) return;
    _pushHistory(_redoStack, _cloneSession(_session));
    _restoreHistorySession(_undoStack.removeLast());
    setState(() => _message = 'Undo complete.');
  }

  void _redo() {
    _finishEditTransaction();
    if (_redoStack.isEmpty) return;
    _pushHistory(_undoStack, _cloneSession(_session));
    _restoreHistorySession(_redoStack.removeLast());
    setState(() => _message = 'Redo complete.');
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(
      const Duration(milliseconds: 1200),
      () => unawaited(_runAutosave()),
    );
  }

  Future<void> _runAutosave() async {
    if (!mounted || _editRevision <= _autosavedRevision) return;
    if (_saving || _autosaving) {
      _scheduleAutosave();
      return;
    }
    _autosaving = true;
    final revision = _editRevision;
    final snapshot = _cloneSession(_session);
    try {
      final path = await _projects.save(snapshot);
      if (!mounted) return;
      setState(() {
        _projectPath = path;
        _autosavedRevision = revision;
        _message = 'Autosaved locally.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = 'Autosave failed: $error');
    } finally {
      _autosaving = false;
      // Retry only when a newer edit arrived during this save. A persistent
      // storage error should be shown once, not retried forever in the UI.
      if (mounted && _editRevision > revision) _scheduleAutosave();
    }
  }

  Future<void> _loadWaveform(String path) async {
    if (_waveformCache.containsKey(path)) return;
    try {
      final data = await _waveforms.analyze(path, peakCount: 512);
      if (!mounted) return;
      setState(() => _waveformCache = {..._waveformCache, path: data});
    } catch (error) {
      if (mounted) setState(() => _message = 'Waveform unavailable: $error');
    }
  }

  AudioSession _withTracks(List<AudioTrack> tracks) => AudioSession(
        id: _session.id,
        title: _session.title,
        sampleRate: _session.sampleRate,
        channels: _session.channels,
        bitDepth: _session.bitDepth,
        tracks: tracks,
        markers: _session.markers,
      );

  void _replaceTrack(AudioTrack updated) {
    final tracks = _session.tracks
        .map((track) => track.id == updated.id ? updated : track)
        .toList();
    _commitSession(_withTracks(tracks));
  }

  void _addTrack() {
    final index = _session.tracks.length + 1;
    final id = 'track-${DateTime.now().microsecondsSinceEpoch}';
    final track = AudioTrack(
      id: id,
      name: 'Voice $index',
      kind: AudioTrackKind.voice,
    );
    _commitSession(_withTracks([..._session.tracks, track]));
    setState(() {
      _selectedTrackId = id;
      _selectedClipId = null;
    });
  }

  Future<void> _addRecordingToTrack({String? targetTrackId}) async {
    List<AudioLibraryRecording> available;
    try {
      available = await _library.listRecordings();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
      return;
    }
    final compatible = available
        .where(
          (item) =>
              item.sampleRate == _session.sampleRate &&
              item.channels <= 2 &&
              item.frameCount > 0,
        )
        .toList();
    if (!mounted) return;
    if (compatible.isEmpty) {
      setState(() {
        _message =
            'No compatible WAV found. This project uses ${_session.sampleRate} Hz; sample-rate conversion is not available yet.';
      });
      return;
    }

    final selected = await showDialog<AudioLibraryRecording>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add recording to track'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: ListView.separated(
            itemCount: compatible.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = compatible[index];
              return ListTile(
                leading: const Icon(Icons.audio_file_rounded),
                title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${_formatDuration(item.duration)} · ${item.sampleRate} Hz · ${item.channels} ch',
                ),
                onTap: () => Navigator.of(dialogContext).pop(item),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    AudioTrack? track;
    if (targetTrackId != null) {
      for (final candidate in _session.tracks) {
        if (candidate.id == targetTrackId) {
          track = candidate;
          break;
        }
      }
    } else {
      track = _selectedTrack;
    }
    if (track == null) {
      _addTrack();
      track = _selectedTrack;
    }
    if (track == null) return;

    var endFrame = 0;
    for (final clip in track.clips) {
      final end = clip.startFrame + clip.durationFrames;
      if (end > endFrame) endFrame = end;
    }
    final clip = AudioClip(
      id: 'clip-${DateTime.now().microsecondsSinceEpoch}',
      mediaId: selected.path,
      startFrame: _snapFrame(
        track.clips.isEmpty ? 0 : endFrame + (_session.sampleRate ~/ 2),
      ),
      sourceStartFrame: 0,
      durationFrames: selected.frameCount,
    );
    final updated = AudioTrack(
      id: track.id,
      name: track.name,
      kind: track.kind,
      gain: track.gain,
      pan: track.pan,
      muted: track.muted,
      solo: track.solo,
      armed: track.armed,
      clips: [...track.clips, clip],
    );
    _replaceTrack(updated);
    setState(() {
      _selectedTrackId = track!.id;
      _selectedClipId = clip.id;
      _message = 'Added ${selected.name} as a non-destructive clip.';
    });
    unawaited(_loadWaveform(selected.path));
  }

  void _selectClip(String trackId, String? clipId) {
    setState(() {
      _selectedTrackId = trackId;
      _selectedClipId = clipId;
    });
  }

  void _beginClipDrag(AudioTrack track, double localX) {
    final frame = (localX / _pixelsPerSecond * _session.sampleRate).round();
    AudioClip? hit;
    for (final clip in track.clips.reversed) {
      if (frame >= clip.startFrame &&
          frame <= clip.startFrame + clip.durationFrames) {
        hit = clip;
        break;
      }
    }
    if (hit == null) {
      _dragTrackId = null;
      _dragClipId = null;
      _lastDragX = null;
      _dragOriginalClip = null;
      return;
    }
    final clipLeft = hit.startFrame / _session.sampleRate * _pixelsPerSecond;
    final clipRight = (hit.startFrame + hit.durationFrames) /
        _session.sampleRate *
        _pixelsPerSecond;
    const handleWidth = 16.0;
    _dragMode = (localX - clipLeft).abs() <= handleWidth
        ? _ClipDragMode.trimStart
        : (localX - clipRight).abs() <= handleWidth
            ? _ClipDragMode.trimEnd
            : _ClipDragMode.move;
    _beginEditTransaction();
    _dragOriginalClip = hit;
    setState(() {
      _selectedTrackId = track.id;
      _selectedClipId = hit!.id;
      _dragTrackId = track.id;
      _dragClipId = hit.id;
      _lastDragX = localX;
    });
  }

  void _dragClipToLocalX(double localX) {
    final previousX = _lastDragX;
    if (_dragTrackId == null ||
        _dragClipId == null ||
        previousX == null ||
        _selectedTrackId != _dragTrackId ||
        _selectedClipId != _dragClipId) {
      return;
    }
    final deltaX = localX - previousX;
    // Keep the initial pointer and clip as the drag anchor. This accumulates
    // sub-grid pointer motion so snapping cannot get stuck between events.
    final clip = _dragOriginalClip ?? _selectedClip;
    if (clip == null || deltaX == 0) return;
    final deltaFrames =
        (deltaX / _pixelsPerSecond * _session.sampleRate).round();
    if (deltaFrames == 0) return;

    if (_dragMode == _ClipDragMode.move) {
      final nextFrame = _snapFrame(
        math.max(0, clip.startFrame + deltaFrames).toInt(),
      );
      if (nextFrame != clip.startFrame) {
        _updateSelectedClip(startFrame: nextFrame);
      }
    } else if (_dragMode == _ClipDragMode.trimStart) {
      final nextStart = _snapFrame(clip.startFrame + deltaFrames);
      final trimFrames = math.max(0, nextStart - clip.startFrame).toInt();
      if (trimFrames <= 0 || trimFrames >= clip.durationFrames) return;
      final trimmed = clip.trimStartByFrames(
        trimFrames,
        newId: clip.id,
      );
      _updateSelectedClip(
        startFrame: trimmed.startFrame,
        sourceStartFrame: trimmed.sourceStartFrame,
        durationFrames: trimmed.durationFrames,
        fadeInFrames: trimmed.fadeInFrames,
        fadeOutFrames: trimmed.fadeOutFrames,
      );
    } else {
      final oldEnd = clip.startFrame + clip.durationFrames;
      final nextEnd = _snapFrame(oldEnd + deltaFrames);
      final nextDuration = nextEnd - clip.startFrame;
      if (nextDuration <= 0 || nextDuration >= clip.durationFrames) return;
      final trimmed = clip.trimEndByFrames(
        clip.durationFrames - nextDuration,
        newId: clip.id,
      );
      _updateSelectedClip(
        durationFrames: trimmed.durationFrames,
        fadeInFrames: trimmed.fadeInFrames,
        fadeOutFrames: trimmed.fadeOutFrames,
      );
    }
  }

  void _endClipDrag() {
    _dragTrackId = null;
    _dragClipId = null;
    _lastDragX = null;
    _dragOriginalClip = null;
    _finishEditTransaction();
  }

  void _updateSelectedClip({
    int? startFrame,
    int? sourceStartFrame,
    int? durationFrames,
    double? gain,
    bool? muted,
    int? fadeInFrames,
    int? fadeOutFrames,
  }) {
    final track = _selectedTrack;
    final clip = _selectedClip;
    if (track == null || clip == null) return;
    final updatedClip = AudioClip(
      id: clip.id,
      mediaId: clip.mediaId,
      startFrame: startFrame ?? clip.startFrame,
      sourceStartFrame: sourceStartFrame ?? clip.sourceStartFrame,
      durationFrames: durationFrames ?? clip.durationFrames,
      gain: gain ?? clip.gain,
      pan: clip.pan,
      muted: muted ?? clip.muted,
      fadeInFrames: fadeInFrames ?? clip.fadeInFrames,
      fadeOutFrames: fadeOutFrames ?? clip.fadeOutFrames,
    );
    final updatedTrack = AudioTrack(
      id: track.id,
      name: track.name,
      kind: track.kind,
      gain: track.gain,
      pan: track.pan,
      muted: track.muted,
      solo: track.solo,
      armed: track.armed,
      clips: track.clips
          .map((item) => item.id == clip.id ? updatedClip : item)
          .toList(),
    );
    _replaceTrack(updatedTrack);
  }

  void _moveSelectedClip(int seconds) {
    final clip = _selectedClip;
    if (clip == null) return;
    final delta = seconds * _session.sampleRate;
    final next = _snapFrame(
      math.max(0, clip.startFrame + delta).toInt(),
    );
    _updateSelectedClip(startFrame: next);
  }

  void _toggleSelectedClipMute() {
    final clip = _selectedClip;
    if (clip == null) return;
    _updateSelectedClip(muted: !clip.muted);
  }

  void _splitSelectedClip() {
    final track = _selectedTrack;
    final clip = _selectedClip;
    if (track == null || clip == null || clip.durationFrames < 2) return;
    final splitOffset = clip.durationFrames ~/ 2;
    try {
      final parts = clip.splitAtFrameOffset(
        splitOffset,
        firstId: 'clip-${DateTime.now().microsecondsSinceEpoch}-a',
        secondId: 'clip-${DateTime.now().microsecondsSinceEpoch}-b',
      );
      final updatedTrack = AudioTrack(
        id: track.id,
        name: track.name,
        kind: track.kind,
        gain: track.gain,
        pan: track.pan,
        muted: track.muted,
        solo: track.solo,
        armed: track.armed,
        clips: [
          for (final item in track.clips)
            if (item.id == clip.id) ...parts else item,
        ],
      );
      _replaceTrack(updatedTrack);
      setState(() {
        _selectedClipId = parts.last.id;
        _message = 'Clip split at frame ${clip.startFrame + splitOffset}. The source WAV remains unchanged.';
      });
    } catch (error) {
      setState(() => _message = error.toString());
    }
  }

  void _crossfadeSelectedWithNext() {
    final track = _selectedTrack;
    final clip = _selectedClip;
    if (track == null || clip == null) return;
    final candidates = track.clips
        .where((item) => item.id != clip.id && item.startFrame >= clip.startFrame)
        .toList()
      ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
    if (candidates.isEmpty) return;
    final next = candidates.first;
    final fadeFrames = math.min(
      _session.sampleRate ~/ 4,
      math.min(clip.durationFrames ~/ 2, next.durationFrames ~/ 2),
    ).toInt();
    if (fadeFrames < 1) return;

    final overlapStart = math.max(
      0,
      clip.startFrame + clip.durationFrames - fadeFrames,
    ).toInt();
    final updatedClip = AudioClip(
      id: clip.id,
      mediaId: clip.mediaId,
      startFrame: clip.startFrame,
      sourceStartFrame: clip.sourceStartFrame,
      durationFrames: clip.durationFrames,
      gain: clip.gain,
      pan: clip.pan,
      muted: clip.muted,
      fadeInFrames: clip.fadeInFrames,
      fadeOutFrames: fadeFrames,
    );
    final updatedNext = AudioClip(
      id: next.id,
      mediaId: next.mediaId,
      startFrame: overlapStart,
      sourceStartFrame: next.sourceStartFrame,
      durationFrames: next.durationFrames,
      gain: next.gain,
      pan: next.pan,
      muted: next.muted,
      fadeInFrames: fadeFrames,
      fadeOutFrames: next.fadeOutFrames,
    );
    _replaceTrack(
      AudioTrack(
        id: track.id,
        name: track.name,
        kind: track.kind,
        gain: track.gain,
        pan: track.pan,
        muted: track.muted,
        solo: track.solo,
        armed: track.armed,
        clips: [
          for (final item in track.clips)
            if (item.id == clip.id)
              updatedClip
            else if (item.id == next.id)
              updatedNext
            else
              item,
        ],
      ),
    );
    final fadeMilliseconds =
        (fadeFrames * 1000 / _session.sampleRate).round();
    setState(() {
      _selectedClipId = clip.id;
      _message = 'Created a $fadeMilliseconds ms crossfade with the next clip.';
    });
  }

  void _removeSelectedClip() {
    final track = _selectedTrack;
    final clip = _selectedClip;
    if (track == null || clip == null) return;
    final updated = AudioTrack(
      id: track.id,
      name: track.name,
      kind: track.kind,
      gain: track.gain,
      pan: track.pan,
      muted: track.muted,
      solo: track.solo,
      armed: track.armed,
      clips: track.clips.where((item) => item.id != clip.id).toList(),
    );
    _replaceTrack(updated);
    setState(() {
      _selectedClipId = null;
      _message = 'Clip removed from the session. The source WAV is unchanged.';
    });
  }

  void _toggleTrackMute(AudioTrack track) {
    _replaceTrack(
      AudioTrack(
        id: track.id,
        name: track.name,
        kind: track.kind,
        gain: track.gain,
        pan: track.pan,
        muted: !track.muted,
        solo: track.solo,
        armed: track.armed,
        clips: track.clips,
      ),
    );
  }

  void _toggleTrackSolo(AudioTrack track) {
    _replaceTrack(
      AudioTrack(
        id: track.id,
        name: track.name,
        kind: track.kind,
        gain: track.gain,
        pan: track.pan,
        muted: track.muted,
        solo: !track.solo,
        armed: track.armed,
        clips: track.clips,
      ),
    );
  }

  Future<void> _saveProject() async {
    if (_saving || _autosaving) return;
    _autosaveTimer?.cancel();
    final revision = _editRevision;
    final snapshot = _cloneSession(_session);
    var saveSucceeded = false;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final path = await _projects.save(snapshot);
      saveSucceeded = true;
      if (mounted) {
        setState(() {
          _projectPath = path;
          _autosavedRevision = revision;
          _message = 'Session saved locally.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (saveSucceeded && _editRevision > revision) _scheduleAutosave();
      }
    }
  }

  Future<void> _startRealtimePlayback() async {
    if (_rendering) return;
    await _stopPlayback();
    if (!mounted) return;
    if (_session.tracks.every((track) => track.clips.isEmpty)) {
      setState(() => _message = 'Add at least one audio clip before playback.');
      return;
    }
    setState(() {
      _rendering = true;
      _message = 'Preparing the realtime multitrack audio graph…';
    });
    try {
      final assets = <String, Uint8List>{};
      var totalAssetBytes = 0;
      const maximumRealtimeInputBytes = 536870912;
      for (final track in _session.tracks) {
        for (final clip in track.clips) {
          if (!assets.containsKey(clip.mediaId)) {
            final bytes = await readAudioFile(clip.mediaId);
            if (bytes.length > maximumRenderInputBytes - totalAssetBytes) {
              throw const AudioEngineUnavailable(
                'Realtime playback is limited to 512 MiB of source WAV data per session. Split the session or use smaller source files.',
              );
            }
            totalAssetBytes += bytes.length;
            assets[clip.mediaId] = bytes;
          }
        }
      }
      final playback = await _engine.startRealtimePlayback(
        session: _session,
        assetWavs: assets,
      );
      try {
        if (_loopEnabled) {
          final selected = _selectedClip;
          final loopStart = selected?.startFrame ?? 0;
          final loopEnd = selected == null
              ? playback.totalFrames
              : selected.startFrame + selected.durationFrames;
          if (loopStart < loopEnd && loopEnd <= playback.totalFrames) {
            await playback.setLoopRange(
              startFrame: loopStart,
              endFrame: loopEnd,
              enabled: true,
            );
          } else if (selected != null) {
            _loopEnabled = false;
            if (mounted) {
              setState(() {
                _message =
                    'The selected clip is not part of the audible playback range; loop was disabled.';
              });
            }
          }
        }
      } catch (_) {
        await playback.stop();
        rethrow;
      }
      if (!mounted) {
        await playback.stop();
        return;
      }
      setState(() {
        _playback = playback;
        _playbackPosition = 0;
        _transportTotalFrames = playback.totalFrames;
        _transportPaused = false;
        _seekPreviewFrame = null;
        _message = 'Realtime multitrack playback playing.';
      });
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: 70),
        (_) => unawaited(_pollPlayback()),
      );
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  Future<void> _pollPlayback() async {
    final playback = _playback;
    if (playback == null || _pollingPlayback) return;
    _pollingPlayback = true;
    try {
      final position = playback.positionFrames;
      final complete = playback.isComplete;
      final failed = playback.hasError;
      if (complete || failed) {
        _playbackTimer?.cancel();
        _playbackTimer = null;
        _playback = null;
        await playback.stop();
        if (mounted) {
          setState(() {
            _playbackPosition = complete ? playback.totalFrames : position;
            _transportPaused = false;
            if (failed) _message = 'The audio output device reported a playback error.';
          });
        }
      } else if (mounted) {
        setState(() => _playbackPosition = position);
      }
    } finally {
      _pollingPlayback = false;
    }
  }

  Future<void> _stopPlayback() async {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    final playback = _playback;
    _playback = null;
    if (playback != null) await playback.stop();
    if (mounted) {
      setState(() {
        _playbackPosition = 0;
        _transportPaused = false;
        _seekPreviewFrame = null;
      });
    }
  }

  Future<void> _toggleTransportPause() async {
    final playback = _playback;
    if (playback == null) return;
    try {
      if (_transportPaused) {
        await playback.resume();
      } else {
        await playback.pause();
      }
      if (mounted) {
        setState(() {
          _transportPaused = !_transportPaused;
          _message = _transportPaused ? 'Playback paused.' : 'Playback resumed.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _toggleLoop() async {
    final enabled = !_loopEnabled;
    final playback = _playback;
    final selected = _selectedClip;
    final loopStart = selected?.startFrame ?? 0;
    final loopEnd = selected == null
        ? playback?.totalFrames ?? _sessionEndFrame
        : selected.startFrame + selected.durationFrames;
    try {
      if (playback != null && enabled) {
        if (loopStart >= loopEnd || loopEnd > playback.totalFrames) {
          throw const AudioEngineUnavailable(
            'The selected clip is outside the audible playback range. Select an audible clip or clear the selection to loop the whole mix.',
          );
        }
        await playback.setLoopRange(
          startFrame: loopStart,
          endFrame: loopEnd,
          enabled: true,
        );
      } else if (playback != null) {
        await playback.setLoopRange(
          startFrame: 0,
          endFrame: playback.totalFrames,
          enabled: false,
        );
      }
      if (mounted) {
        setState(() {
          _loopEnabled = enabled;
          _message = !enabled
              ? 'Loop disabled. Playback will continue to the end.'
              : selected == null
                  ? 'Whole-mix loop enabled.'
                  : 'Selected clip loop enabled.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  void _previewSeek(double frame) {
    setState(() => _seekPreviewFrame =
        frame.round().clamp(0, _transportTotalFrames).toInt());
  }

  Future<void> _commitSeek(double frame) async {
    final playback = _playback;
    if (playback == null) return;
    final target = frame.round().clamp(0, playback.totalFrames).toInt();
    try {
      await playback.seek(target);
      if (mounted) {
        setState(() {
          _playbackPosition = target;
          _seekPreviewFrame = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _seekPreviewFrame = null;
          _message = error.toString();
        });
      }
    }
  }

  String _formatTransportPosition(int frames) {
    final totalMilliseconds = frames * 1000 ~/ _session.sampleRate;
    final minutes = (totalMilliseconds ~/ 60000).toString().padLeft(2, '0');
    final wholeSeconds =
        ((totalMilliseconds ~/ 1000) % 60).toString().padLeft(2, '0');
    final milliseconds =
        (totalMilliseconds % 1000).toString().padLeft(3, '0');
    return '$minutes:$wholeSeconds.$milliseconds';
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final selectedClip = _selectedClip;
    final selectedTrack = _selectedTrack;
    final timelineWidth = _timelineWidth;
    final pixelsPerSecond = _pixelsPerSecond;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: _redoStack.isEmpty ? null : _redo,
            icon: const Icon(Icons.redo_rounded),
          ),
          IconButton(
            tooltip: 'Add track',
            onPressed: _addTrack,
            icon: const Icon(Icons.add_box_outlined),
          ),
          IconButton(
            tooltip: _autosaving ? 'Autosaving session' : 'Save session',
            onPressed: _saving || _autosaving ? null : _saveProject,
            icon: _saving || _autosaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: _playback == null ? 'Start realtime mix' : 'Stop realtime mix',
            onPressed: _rendering
                ? null
                : _playback == null
                    ? _startRealtimePlayback
                    : _stopPlayback,
            icon: _rendering
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _playback == null
                        ? Icons.play_circle_outline_rounded
                        : Icons.stop_circle_outlined,
                    color: AuraTheme.mint,
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 205,
                    child: Text(
                      '${_session.sampleRate} Hz · ${_session.channels} channel(s) · '
                      '${_session.tracks.length} tracks',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AuraTheme.muted,
                          ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch.adaptive(
                        value: _snapEnabled,
                        onChanged: (value) => setState(() => _snapEnabled = value),
                      ),
                      const Text('Snap'),
                      const SizedBox(width: 4),
                      DropdownButton<int>(
                        value: _snapGridMilliseconds,
                        underline: const SizedBox.shrink(),
                        isDense: true,
                        items: const [
                          DropdownMenuItem(value: 10, child: Text('10 ms')),
                          DropdownMenuItem(value: 50, child: Text('50 ms')),
                          DropdownMenuItem(value: 100, child: Text('100 ms')),
                          DropdownMenuItem(value: 250, child: Text('250 ms')),
                          DropdownMenuItem(value: 500, child: Text('500 ms')),
                          DropdownMenuItem(value: 1000, child: Text('1 s')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _snapGridMilliseconds = value);
                          }
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Zoom out',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _setTimelineZoom(_timelineZoom / 1.25),
                        icon: const Icon(Icons.zoom_out_rounded),
                      ),
                      Text('${(_timelineZoom * 100).round()}%'),
                      IconButton(
                        tooltip: 'Zoom in',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _setTimelineZoom(_timelineZoom * 1.25),
                        icon: const Icon(Icons.zoom_in_rounded),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: _addRecordingToTrack,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add recording'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: 210 + timelineWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 210,
                              height: 32,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'TRACKS / TIMELINE',
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: AuraTheme.muted,
                                          letterSpacing: 1.1,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: timelineWidth,
                              height: 32,
                              child: CustomPaint(
                                painter: _TimelineRulerPainter(
                                  pixelsPerSecond: pixelsPerSecond,
                                  totalSeconds: _totalSeconds,
                                  sampleRate: _session.sampleRate,
                                  playheadFrame:
                                      _playback == null ? null : _playbackPosition,
                                ),
                              ),
                            ),
                          ],
                        ),
                        for (final track in _session.tracks)
                          Row(
                            children: [
                              _TrackHeader(
                                track: track,
                                selected: track.id == _selectedTrackId,
                                onSelect: () => setState(() {
                                  _selectedTrackId = track.id;
                                  _selectedClipId = null;
                                }),
                                onMute: () => _toggleTrackMute(track),
                                onSolo: () => _toggleTrackSolo(track),
                                onAddClip: () =>
                                    _addRecordingToTrack(targetTrackId: track.id),
                              ),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) {
                                  final frame = (details.localPosition.dx /
                                          pixelsPerSecond *
                                          _session.sampleRate)
                                      .round();
                                  AudioClip? hit;
                                  for (final clip in track.clips.reversed) {
                                    if (frame >= clip.startFrame &&
                                        frame <= clip.startFrame + clip.durationFrames) {
                                      hit = clip;
                                      break;
                                    }
                                  }
                                  _selectClip(track.id, hit?.id);
                                },
                                onLongPressStart: (details) =>
                                    _beginClipDrag(track, details.localPosition.dx),
                                onLongPressMoveUpdate: (details) =>
                                    _dragClipToLocalX(details.localPosition.dx),
                                onLongPressEnd: (_) => _endClipDrag(),
                                onLongPressCancel: _endClipDrag,
                                child: SizedBox(
                                  width: timelineWidth,
                                  height: 112,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      RepaintBoundary(
                                        child: CustomPaint(
                                          painter: _TrackWaveformPainter(
                                            track: track,
                                            waveforms: _waveformCache,
                                            sampleRate: _session.sampleRate,
                                            pixelsPerSecond: pixelsPerSecond,
                                            selectedClipId: _selectedClipId,
                                          ),
                                        ),
                                      ),
                                      if (_playback != null)
                                        IgnorePointer(
                                          child: CustomPaint(
                                            painter: _PlayheadPainter(
                                              sampleRate: _session.sampleRate,
                                              pixelsPerSecond: pixelsPerSecond,
                                              frame: _playbackPosition,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (_session.tracks.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Add a track to start arranging audio.'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (selectedClip != null && selectedTrack != null)
              _SelectedClipPanel(
                clip: selectedClip,
                trackName: selectedTrack.name,
                onMoveLeft: () => _moveSelectedClip(-1),
                onMoveRight: () => _moveSelectedClip(1),
                onToggleMute: _toggleSelectedClipMute,
                onRemove: _removeSelectedClip,
                onSplit: _splitSelectedClip,
                onCrossfade: _crossfadeSelectedWithNext,
                canCrossfade: selectedTrack.clips.any(
                  (clip) => clip.id != selectedClip.id &&
                      clip.startFrame >= selectedClip.startFrame,
                ),
                onTransactionStart: _beginEditTransaction,
                onTransactionEnd: _finishEditTransaction,
                maxFadeFrames: math.min(
                  selectedClip.durationFrames,
                  _session.sampleRate * 5,
                ).toInt(),
                sampleRate: _session.sampleRate,
                onGainChanged: (value) => _updateSelectedClip(gain: value),
                onFadeInChanged: (value) =>
                    _updateSelectedClip(fadeInFrames: value.round()),
                onFadeOutChanged: (value) =>
                    _updateSelectedClip(fadeOutFrames: value.round()),
              ),
            if (_projectPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  _projectPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AuraTheme.muted,
                      ),
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: Text(
                  _message!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFFC27A),
                      ),
                ),
              ),
            if (_playback != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: _transportPaused ? 'Resume playback' : 'Pause playback',
                          onPressed: _toggleTransportPause,
                          icon: Icon(
                            _transportPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            color: AuraTheme.mint,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Stop playback',
                          onPressed: _stopPlayback,
                          icon: const Icon(Icons.stop_rounded),
                        ),
                        IconButton(
                          tooltip: _loopEnabled
                              ? 'Disable loop'
                              : _selectedClip == null
                                  ? 'Loop whole mix'
                                  : 'Loop selected clip',
                          onPressed: _toggleLoop,
                          color: _loopEnabled ? AuraTheme.mint : null,
                          icon: const Icon(Icons.repeat_rounded),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatTransportPosition(
                            _seekPreviewFrame ?? _playbackPosition,
                          ),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const Spacer(),
                        Text(
                          _formatTransportPosition(_transportTotalFrames),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AuraTheme.muted,
                              ),
                        ),
                      ],
                    ),
                    Slider(
                      min: 0,
                      max: math.max(1, _transportTotalFrames).toDouble(),
                      value: (_seekPreviewFrame ?? _playbackPosition)
                          .clamp(0, math.max(1, _transportTotalFrames))
                          .toDouble(),
                      onChanged: _previewSeek,
                      onChangeEnd: _commitSeek,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({
    required this.track,
    required this.selected,
    required this.onSelect,
    required this.onMute,
    required this.onSolo,
    required this.onAddClip,
  });

  final AudioTrack track;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onMute;
  final VoidCallback onSolo;
  final VoidCallback onAddClip;

  @override
  Widget build(BuildContext context) => Container(
        width: 210,
        height: 112,
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: selected ? AuraTheme.panelLight : AuraTheme.panel,
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            right: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onSelect,
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded, size: 17, color: AuraTheme.mint),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add clip to this track',
                    visualDensity: VisualDensity.compact,
                    onPressed: onAddClip,
                    icon: const Icon(Icons.add_rounded, size: 17),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Row(
              children: [
                _TrackMiniButton(
                  label: 'M',
                  active: track.muted,
                  tooltip: 'Mute track',
                  onPressed: onMute,
                ),
                const SizedBox(width: 6),
                _TrackMiniButton(
                  label: 'S',
                  active: track.solo,
                  tooltip: 'Solo track',
                  onPressed: onSolo,
                ),
                const Spacer(),
                Text(
                  '${track.clips.length} clips',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: AuraTheme.muted,
                      ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _TrackMiniButton extends StatelessWidget {
  const _TrackMiniButton({
    required this.label,
    required this.active,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            width: 25,
            height: 23,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? AuraTheme.mint : AuraTheme.panelLight,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: active ? const Color(0xFF07151A) : Colors.white70,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ),
      );
}

class _SelectedClipPanel extends StatelessWidget {
  const _SelectedClipPanel({
    required this.clip,
    required this.trackName,
    required this.maxFadeFrames,
    required this.sampleRate,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onToggleMute,
    required this.onRemove,
    required this.onSplit,
    required this.onCrossfade,
    required this.canCrossfade,
    required this.onTransactionStart,
    required this.onTransactionEnd,
    required this.onGainChanged,
    required this.onFadeInChanged,
    required this.onFadeOutChanged,
  });

  final AudioClip clip;
  final String trackName;
  final int maxFadeFrames;
  final int sampleRate;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback onToggleMute;
  final VoidCallback onRemove;
  final VoidCallback onSplit;
  final VoidCallback onCrossfade;
  final bool canCrossfade;
  final VoidCallback onTransactionStart;
  final VoidCallback onTransactionEnd;
  final ValueChanged<double> onGainChanged;
  final ValueChanged<double> onFadeInChanged;
  final ValueChanged<double> onFadeOutChanged;

  String _milliseconds(int frames) =>
      (frames * 1000 / sampleRate).round().toString();

  bool get _canSplit {
    if (clip.durationFrames < 2) return false;
    final midpoint = clip.durationFrames ~/ 2;
    return clip.fadeInFrames <= midpoint &&
        clip.fadeOutFrames <= clip.durationFrames - midpoint;
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: AuraTheme.panel,
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$trackName · Clip',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                IconButton(
                  tooltip: 'Split clip at midpoint',
                  onPressed: _canSplit ? onSplit : null,
                  icon: const Icon(Icons.content_cut_rounded),
                ),
                IconButton(
                  tooltip: 'Crossfade with next clip (up to 250 ms)',
                  onPressed: canCrossfade ? onCrossfade : null,
                  icon: const Icon(Icons.compare_arrows_rounded),
                ),
                IconButton(
                  tooltip: 'Move left one second',
                  onPressed: onMoveLeft,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                IconButton(
                  tooltip: 'Move right one second',
                  onPressed: onMoveRight,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
                IconButton(
                  tooltip: clip.muted ? 'Unmute clip' : 'Mute clip',
                  onPressed: onToggleMute,
                  icon: Icon(
                    clip.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove clip from session',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE58A8A)),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Long-press a white clip edge to trim inward · original WAV stays untouched',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AuraTheme.muted,
                    ),
              ),
            ),
            _ClipValueSlider(
              label: 'Gain',
              value: clip.gain,
              min: 0,
              max: 2,
              valueLabel: '${(clip.gain * 100).round()}%',
              onChanged: onGainChanged,
              onChangeStart: onTransactionStart,
              onChangeEnd: onTransactionEnd,
            ),
            _ClipValueSlider(
              label: 'Fade In',
              value: clip.fadeInFrames.toDouble(),
              min: 0,
              max: math.max(1, maxFadeFrames).toDouble(),
              valueLabel: '${_milliseconds(clip.fadeInFrames)} ms',
              onChanged: onFadeInChanged,
              onChangeStart: onTransactionStart,
              onChangeEnd: onTransactionEnd,
            ),
            _ClipValueSlider(
              label: 'Fade Out',
              value: clip.fadeOutFrames.toDouble(),
              min: 0,
              max: math.max(1, maxFadeFrames).toDouble(),
              valueLabel: '${_milliseconds(clip.fadeOutFrames)} ms',
              onChanged: onFadeOutChanged,
              onChangeStart: onTransactionStart,
              onChangeEnd: onTransactionEnd,
            ),
          ],
        ),
      );
}

class _ClipValueSlider extends StatelessWidget {
  const _ClipValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(width: 62, child: Text(label)),
          Expanded(
            child: Slider(
              min: min,
              max: max,
              value: value.clamp(min, max).toDouble(),
              onChanged: onChanged,
              onChangeStart: onChangeStart == null ? null : (_) => onChangeStart!(),
              onChangeEnd: onChangeEnd == null ? null : (_) => onChangeEnd!(),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              valueLabel,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      );
}

class _TimelineRulerPainter extends CustomPainter {
  const _TimelineRulerPainter({
    required this.pixelsPerSecond,
    required this.totalSeconds,
    required this.sampleRate,
    required this.playheadFrame,
  });

  final double pixelsPerSecond;
  final double totalSeconds;
  final int sampleRate;
  final int? playheadFrame;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    final textStyle = const TextStyle(
      color: Colors.white54,
      fontSize: 10,
    );
    for (var second = 0; second <= totalSeconds.ceil(); second++) {
      final x = second * pixelsPerSecond;
      canvas.drawLine(Offset(x, 19), Offset(x, size.height), line);
      if (second % 5 == 0) {
        final painter = TextPainter(
          text: TextSpan(text: '${second}s', style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, Offset(x + 4, 2));
      }
    }
    final frame = playheadFrame;
    if (frame != null) {
      final x = (frame / sampleRate * pixelsPerSecond)
          .clamp(0.0, size.width)
          .toDouble();
      final playheadPaint = Paint()
        ..color = AuraTheme.mint
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), playheadPaint);
      final head = Path()
        ..moveTo(x - 5, 0)
        ..lineTo(x + 5, 0)
        ..lineTo(x, 7)
        ..close();
      canvas.drawPath(head, Paint()..color = AuraTheme.mint);
    }
  }

  @override
  bool shouldRepaint(covariant _TimelineRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerSecond != pixelsPerSecond ||
      oldDelegate.totalSeconds != totalSeconds ||
      oldDelegate.sampleRate != sampleRate ||
      oldDelegate.playheadFrame != playheadFrame;
}

class _PlayheadPainter extends CustomPainter {
  const _PlayheadPainter({
    required this.sampleRate,
    required this.pixelsPerSecond,
    required this.frame,
  });

  final int sampleRate;
  final double pixelsPerSecond;
  final int frame;

  @override
  void paint(Canvas canvas, Size size) {
    final x = (frame / sampleRate * pixelsPerSecond)
        .clamp(0.0, size.width)
        .toDouble();
    final paint = Paint()
      ..color = AuraTheme.mint
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter oldDelegate) =>
      oldDelegate.sampleRate != sampleRate ||
      oldDelegate.pixelsPerSecond != pixelsPerSecond ||
      oldDelegate.frame != frame;
}

class _TrackWaveformPainter extends CustomPainter {
  const _TrackWaveformPainter({
    required this.track,
    required this.waveforms,
    required this.sampleRate,
    required this.pixelsPerSecond,
    required this.selectedClipId,
  });

  final AudioTrack track;
  final Map<String, AudioWaveformData> waveforms;
  final int sampleRate;
  final double pixelsPerSecond;
  final String? selectedClipId;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFF111A2B), BlendMode.src);
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.055)
      ..strokeWidth = 1;
    final seconds = (size.width / pixelsPerSecond).ceil();
    for (var second = 0; second <= seconds; second++) {
      final x = second * pixelsPerSecond;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      grid,
    );

    for (final clip in track.clips) {
      final left = clip.startFrame / sampleRate * pixelsPerSecond;
      final rawWidth = clip.durationFrames / sampleRate * pixelsPerSecond;
      final width = math.max(24.0, rawWidth).toDouble();
      final rect = Rect.fromLTWH(left, 10, width, size.height - 20);
      final isSelected = clip.id == selectedClipId;
      final fill = Paint()
        ..color = clip.muted
            ? const Color(0xFF48515E)
            : isSelected
                ? AuraTheme.violet.withValues(alpha: 0.25)
                : AuraTheme.mint.withValues(alpha: 0.15);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        fill,
      );
      final outline = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2 : 1
        ..color = isSelected ? AuraTheme.violet : AuraTheme.mint;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        outline,
      );
      if (isSelected) {
        final handlePaint = Paint()..color = Colors.white.withValues(alpha: 0.9);
        final leftHandle = RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + 2, rect.top + 2, 5, 18),
          const Radius.circular(2),
        );
        final rightHandle = RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.right - 7, rect.top + 2, 5, 18),
          const Radius.circular(2),
        );
        canvas.drawRRect(leftHandle, handlePaint);
        canvas.drawRRect(rightHandle, handlePaint);
      }

      final waveform = waveforms[clip.mediaId];
      if (waveform != null &&
          waveform.peaks.isNotEmpty &&
          waveform.frameCount > 0) {
        final peaks = waveform.peaks;
        final firstPeak = (clip.sourceStartFrame * peaks.length /
                waveform.frameCount)
            .floor()
            .clamp(0, peaks.length - 1)
            .toInt();
        final afterLastPeak = ((clip.sourceStartFrame + clip.durationFrames) *
                peaks.length /
                waveform.frameCount)
            .ceil()
            .clamp(firstPeak + 1, peaks.length)
            .toInt();
        final visibleCount = afterLastPeak - firstPeak;
        final center = rect.center.dy;
        final barPaint = Paint()
          ..color = clip.muted ? Colors.white38 : AuraTheme.mint
          ..strokeWidth =
              math.max(1.0, width / visibleCount * 0.7).toDouble()
          ..strokeCap = StrokeCap.round;
        for (var index = 0; index < visibleCount; index++) {
          final peak = peaks[firstPeak + index];
          final x = rect.left + (index + 0.5) / visibleCount * rect.width;
          final height = math.max(1.0, peak * rect.height * 0.42).toDouble();
          canvas.drawLine(
            Offset(x, center - height),
            Offset(x, center + height),
            barPaint,
          );
        }
      } else {
        final label = TextPainter(
          text: const TextSpan(
            text: 'Loading waveform…',
            style: TextStyle(color: Colors.white60, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: math.max(20.0, rect.width - 12).toDouble());
        label.paint(canvas, Offset(rect.left + 6, rect.center.dy - 6));
      }

      final title = TextPainter(
        text: TextSpan(
          text: _clipName(clip.mediaId),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(20.0, rect.width - 12).toDouble());
      title.paint(canvas, Offset(rect.left + 6, rect.top + 4));
    }
  }

  String _clipName(String path) {
    final name = path.split(RegExp(r'[/\\\\]')).last;
    return name.toLowerCase().endsWith('.wav')
        ? name.substring(0, name.length - 4)
        : name;
  }

  @override
  bool shouldRepaint(covariant _TrackWaveformPainter oldDelegate) =>
      oldDelegate.track != track ||
      oldDelegate.waveforms != waveforms ||
      oldDelegate.sampleRate != sampleRate ||
      oldDelegate.pixelsPerSecond != pixelsPerSecond ||
      oldDelegate.selectedClipId != selectedClipId;
}
