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
      math.max(900.0, math.min(7200.0, _totalSeconds * 76.0)).toDouble();

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
    setState(() => _session = _withTracks(tracks));
  }

  void _addTrack() {
    final index = _session.tracks.length + 1;
    final id = 'track-${DateTime.now().microsecondsSinceEpoch}';
    final track = AudioTrack(
      id: id,
      name: 'Voice $index',
      kind: AudioTrackKind.voice,
    );
    setState(() {
      _session = _withTracks([..._session.tracks, track]);
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
      startFrame: track.clips.isEmpty
          ? 0
          : endFrame + (_session.sampleRate ~/ 2),
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
      return;
    }
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
    _lastDragX = localX;
    final clip = _selectedClip;
    if (clip == null || deltaX == 0) return;
    final deltaFrames =
        (deltaX / _pixelsPerSecond * _session.sampleRate).round();
    if (deltaFrames == 0) return;
    final nextFrame = math.max(0, clip.startFrame + deltaFrames).toInt();
    _updateSelectedClip(startFrame: nextFrame);
  }

  void _endClipDrag() {
    _dragTrackId = null;
    _dragClipId = null;
    _lastDragX = null;
  }

  void _updateSelectedClip({
    int? startFrame,
    double? gain,
    bool? muted,
  }) {
    final track = _selectedTrack;
    final clip = _selectedClip;
    if (track == null || clip == null) return;
    final updatedClip = AudioClip(
      id: clip.id,
      mediaId: clip.mediaId,
      startFrame: startFrame ?? clip.startFrame,
      sourceStartFrame: clip.sourceStartFrame,
      durationFrames: clip.durationFrames,
      gain: gain ?? clip.gain,
      pan: clip.pan,
      muted: muted ?? clip.muted,
      fadeInFrames: clip.fadeInFrames,
      fadeOutFrames: clip.fadeOutFrames,
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
    final next = math.max(0, clip.startFrame + delta).toInt();
    _updateSelectedClip(startFrame: next);
  }

  void _toggleSelectedClipMute() {
    final clip = _selectedClip;
    if (clip == null) return;
    _updateSelectedClip(muted: !clip.muted);
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
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final path = await _projects.save(_session);
      if (mounted) {
        setState(() {
          _projectPath = path;
          _message = 'Session saved locally.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _renderAndPlay() async {
    if (_rendering) return;
    await _stopPlayback();
    if (!mounted) return;
    if (_session.tracks.every((track) => track.clips.isEmpty)) {
      setState(() => _message = 'Add at least one audio clip before rendering.');
      return;
    }
    setState(() {
      _rendering = true;
      _message = 'Rendering the current session…';
    });
    try {
      final assets = <String, Uint8List>{};
      for (final track in _session.tracks) {
        for (final clip in track.clips) {
          if (!assets.containsKey(clip.mediaId)) {
            assets[clip.mediaId] = await readAudioFile(clip.mediaId);
          }
        }
      }
      final result = await _engine.renderSession(
        session: _session,
        assetWavs: assets,
        bitDepth: _session.bitDepth,
      );
      if (!mounted) return;
      final playback = await _engine.startPlayback(wavBytes: result.wavBytes);
      if (!mounted) {
        await playback.stop();
        return;
      }
      setState(() {
        _playback = playback;
        _playbackPosition = 0;
        _message = result.clippedSamples > 0
            ? 'Mix preview playing · ${result.clippedSamples} clipped samples were detected.'
            : 'Mix preview playing · no clipped samples detected.';
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
    if (mounted) setState(() => _playbackPosition = 0);
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
            tooltip: 'Add track',
            onPressed: _addTrack,
            icon: const Icon(Icons.add_box_outlined),
          ),
          IconButton(
            tooltip: 'Save session',
            onPressed: _saving ? null : _saveProject,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: _playback == null ? 'Render and play mix' : 'Stop mix preview',
            onPressed: _rendering
                ? null
                : _playback == null
                    ? _renderAndPlay
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
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_session.sampleRate} Hz · ${_session.channels} channel(s) · '
                      '${_session.tracks.length} tracks',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AuraTheme.muted,
                          ),
                    ),
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
                                child: CustomPaint(
                                  size: Size(timelineWidth, 112),
                                  painter: _TrackWaveformPainter(
                                    track: track,
                                    waveforms: _waveformCache,
                                    sampleRate: _session.sampleRate,
                                    pixelsPerSecond: pixelsPerSecond,
                                    selectedClipId: _selectedClipId,
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
                onGainChanged: (value) => _updateSelectedClip(gain: value),
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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: LinearProgressIndicator(
                  value: _playback!.totalFrames == 0
                      ? 0
                      : (_playbackPosition / _playback!.totalFrames)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                  minHeight: 4,
                  color: AuraTheme.mint,
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
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onToggleMute,
    required this.onRemove,
    required this.onGainChanged,
  });

  final AudioClip clip;
  final String trackName;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final VoidCallback onToggleMute;
  final VoidCallback onRemove;
  final ValueChanged<double> onGainChanged;

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
            Row(
              children: [
                const SizedBox(width: 50, child: Text('Gain')),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 2,
                    value: clip.gain.clamp(0.0, 2.0).toDouble(),
                    onChanged: onGainChanged,
                  ),
                ),
                SizedBox(
                  width: 45,
                  child: Text(
                    '${(clip.gain * 100).round()}%',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _TimelineRulerPainter extends CustomPainter {
  const _TimelineRulerPainter({
    required this.pixelsPerSecond,
    required this.totalSeconds,
  });

  final double pixelsPerSecond;
  final double totalSeconds;

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
  }

  @override
  bool shouldRepaint(covariant _TimelineRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerSecond != pixelsPerSecond ||
      oldDelegate.totalSeconds != totalSeconds;
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

      final waveform = waveforms[clip.mediaId];
      if (waveform != null && waveform.peaks.isNotEmpty) {
        final peaks = waveform.peaks;
        final center = rect.center.dy;
        final barPaint = Paint()
          ..color = clip.muted ? Colors.white38 : AuraTheme.mint
          ..strokeWidth = math.max(1.0, width / peaks.length * 0.7).toDouble()
          ..strokeCap = StrokeCap.round;
        for (var index = 0; index < peaks.length; index++) {
          final x = rect.left + (index + 0.5) / peaks.length * rect.width;
          final height = math.max(1.0, peaks[index] * rect.height * 0.42).toDouble();
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
