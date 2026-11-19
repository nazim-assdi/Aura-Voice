import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:material_ui/material_ui.dart';

import '../../core/services/api_client.dart';
import '../../core/services/audio_engine_service.dart';
import '../../core/services/audio_file_service.dart';
import '../../core/services/audio_library_service.dart';
import '../../core/services/audio_project_service.dart';
import '../../core/services/audio_recording_service.dart';
import '../../core/services/audio_waveform_service.dart';
import '../../core/theme/aura_theme.dart';
import '../editor/audio_editor_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardPage(onOpenStudio: () => setState(() => _index = 1)),
      const StudioPage(),
      const LibraryPage(),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.graphic_eq_rounded), label: 'Studio'),
          NavigationDestination(icon: Icon(Icons.library_music_rounded), label: 'Library'),
        ],
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({required this.onOpenStudio, super.key});
  final VoidCallback onOpenStudio;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              const _TopBar(),
              const SizedBox(height: 34),
              Text('PROFESSIONAL VOICE PRODUCTION',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AuraTheme.mint, letterSpacing: 2.1, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('Record with clarity.\nCreate with control.',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    height: 1.06, fontWeight: FontWeight.w800, letterSpacing: -1.1)),
              const SizedBox(height: 22),
              _HeroPanel(onOpenStudio: onOpenStudio),
              const SizedBox(height: 26),
              Row(children: [
                Text('Your workspace',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                const _StatusChip(label: 'IN DEVELOPMENT'),
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth > 720 ? 4 : 2;
                final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
                const features = [
                  _FeatureData(
                    Icons.record_voice_over_rounded,
                    'Record Booth',
                    'Live meters + 24-bit WAV',
                    AuraTheme.mint,
                    status: 'PARTIAL',
                  ),
                  _FeatureData(Icons.tune_rounded, 'Multitrack Editor', 'Arrange voice tracks', AuraTheme.violet),
                  _FeatureData(Icons.multitrack_audio_rounded, 'Voice Processing', 'EQ, dynamics, cleanup', Color(0xFFFFC27A)),
                  _FeatureData(Icons.translate_rounded, 'AI Voice Studio', 'Text to speech', Color(0xFF80B8FF)),
                ];
                return Wrap(
                  spacing: 12, runSpacing: 12,
                  children: features.map((f) => SizedBox(width: width, child: _FeatureCard(data: f))).toList(),
                );
              }),
              const SizedBox(height: 24),
              const _ApiStatusPanel(),
              const SizedBox(height: 12),
              const _NativeEngineStatusPanel(),
              const SizedBox(height: 12),
              const Wrap(spacing: 10, runSpacing: 10, children: [
                _FeaturePill(label: 'Dubbing & Localization'),
                _FeaturePill(label: 'Mix & Master'),
              ]),
              const SizedBox(height: 18),
              Text(
                'Native microphone capture, live input meters and local 24-bit WAV recording are now in the Studio. Multitrack editing, playback, live monitoring and AI speech remain in development; CI verification is still pending.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted, height: 1.5),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(colors: [AuraTheme.mint, AuraTheme.violet]),
      ),
      child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF0B1421), size: 25),
    ),
    const SizedBox(width: 12),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('AURA', style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w900, letterSpacing: 2.5)),
      Text('VOICE STUDIO', style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AuraTheme.muted, letterSpacing: 2.2)),
    ]),
    const Spacer(),
    const _StatusChip(label: 'HYBRID'),
    const SizedBox(width: 8),
    const CircleAvatar(radius: 19, backgroundColor: AuraTheme.panelLight,
      child: Icon(Icons.person_outline_rounded, color: Colors.white70)),
  ]);
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.onOpenStudio});
  final VoidCallback onOpenStudio;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: const LinearGradient(
        colors: [Color(0xFF183447), Color(0xFF25264A), Color(0xFF171C32)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
      border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const _StatusChip(label: 'VOICE PRODUCTION'),
        const Spacer(),
        Icon(Icons.auto_awesome_rounded, color: AuraTheme.mint.withValues(alpha: 0.9)),
      ]),
      const SizedBox(height: 28),
      Text('Your voice.\nYour sound.',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800, height: 1.08)),
      const SizedBox(height: 10),
      Text('Record, edit, generate, restore and master speech in one focused audio workspace.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70, height: 1.5)),
      const SizedBox(height: 22),
      FilledButton.icon(
        onPressed: onOpenStudio,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: const Text('Open Voice Studio'),
        style: FilledButton.styleFrom(
          backgroundColor: AuraTheme.mint, foregroundColor: const Color(0xFF07151A),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
      ),
    ]),
  );
}

class _FeatureData {
  const _FeatureData(
    this.icon,
    this.title,
    this.subtitle,
    this.accent, {
    this.status = 'PLANNED',
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final String status;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.data});
  final _FeatureData data;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: AuraTheme.panel, borderRadius: BorderRadius.circular(19),
      border: Border.all(color: Colors.white.withValues(alpha: 0.055))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        height: 38, width: 38,
        decoration: BoxDecoration(color: data.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12)),
        child: Icon(data.icon, color: data.accent, size: 21)),
      const SizedBox(height: 18),
      Text(data.title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(data.subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
      const SizedBox(height: 12),
      Text(data.status, style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: data.status == 'PARTIAL' ? AuraTheme.mint : AuraTheme.muted,
        letterSpacing: 1.2)),
    ]),
  );
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: AuraTheme.panelLight,
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white70)),
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(30),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07))),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Colors.white70, letterSpacing: 1.1, fontWeight: FontWeight.w700)),
  );
}

class _ApiStatusPanel extends StatelessWidget {
  const _ApiStatusPanel();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(color: AuraTheme.panel, borderRadius: BorderRadius.circular(18)),
    child: Row(children: [
      const Icon(Icons.cloud_outlined, color: AuraTheme.mint),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('AI provider connection', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 3),
        Text('Cloud speech engine availability',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
      ])),
      FutureBuilder<bool>(
        future: const ApiClient().isApiHealthy(),
        builder: (context, snapshot) {
          final label = snapshot.connectionState != ConnectionState.done
              ? 'CHECKING' : snapshot.data == true ? 'API ONLINE' : 'API OFFLINE';
          return _StatusChip(label: label);
        },
      ),
    ]),
  );
}

class _NativeEngineStatusPanel extends StatefulWidget {
  const _NativeEngineStatusPanel({super.key});

  @override
  State<_NativeEngineStatusPanel> createState() =>
      _NativeEngineStatusPanelState();
}

class _NativeEngineStatusPanelState extends State<_NativeEngineStatusPanel> {
  late final AudioEngineService _engine;

  @override
  void initState() {
    super.initState();
    _engine = createAudioEngineService();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _engine.isAvailable;
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: AuraTheme.panel,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            Icons.memory_rounded,
            color: ready ? AuraTheme.mint : AuraTheme.muted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Native offline audio engine',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  ready
                      ? 'Renderer library detected'
                      : 'Renderer library not installed in this build',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AuraTheme.muted),
                ),
              ],
            ),
          ),
          _StatusChip(label: ready ? 'ENGINE READY' : 'NOT LINKED'),
        ],
      ),
    );
  }
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  late final AudioEngineService _engine;
  final List<AudioInputDevice> _devices = [];
  AudioCaptureSession? _capture;
  AudioRecordingWriter? _writer;
  AudioPlaybackSession? _playback;
  Timer? _meterTimer;
  Timer? _playbackTimer;
  String? _savedPath;
  String? _selectedDeviceId;
  String? _message;
  bool _loadingDevices = true;
  bool _starting = false;
  bool _polling = false;
  bool _stopping = false;
  double _peak = 0;
  double _rms = 0;
  int _sampleRate = 0;
  int _channels = 0;
  int _capturedFrames = 0;
  int _droppedFrames = 0;
  int _playbackPosition = 0;

  @override
  void initState() {
    super.initState();
    _engine = createAudioEngineService();
    unawaited(_refreshDevices());
  }

  @override
  void dispose() {
    _meterTimer?.cancel();
    _playbackTimer?.cancel();
    unawaited(_stopPlayback());
    unawaited(_stopRecording());
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    if (mounted) {
      setState(() {
        _loadingDevices = true;
        _message = null;
      });
    }
    try {
      final devices = await _engine.listInputDevices();
      if (!mounted) return;
      setState(() {
        _devices
          ..clear()
          ..addAll(devices);
        if (!_devices.any((device) => device.id == _selectedDeviceId)) {
          final defaults = _devices.where((device) => device.isDefault);
          _selectedDeviceId = defaults.isNotEmpty
              ? defaults.first.id
              : (_devices.isEmpty ? null : _devices.first.id);
        }
        if (_devices.isEmpty) {
          _message = 'No microphone input was found. Connect a microphone and refresh.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _startRecording() async {
    if (_starting || _capture != null) return;
    await _stopPlayback();
    if (!mounted) return;
    setState(() {
      _starting = true;
      _message = null;
      _peak = 0;
      _rms = 0;
      _capturedFrames = 0;
      _droppedFrames = 0;
    });
    AudioCaptureSession? capture;
    AudioRecordingWriter? writer;
    try {
      final activeCapture = await _engine.startCapture(
        deviceId: _selectedDeviceId,
        bufferMilliseconds: 1000,
      );
      capture = activeCapture;
      final activeWriter = createAudioRecordingWriter();
      writer = activeWriter;
      await activeWriter.start(
        sampleRate: activeCapture.sampleRate,
        channels: activeCapture.channels,
      );
      if (!mounted) {
        await activeCapture.stop();
        await activeWriter.discard();
        return;
      }
      setState(() {
        _capture = activeCapture;
        _writer = activeWriter;
        _sampleRate = activeCapture.sampleRate;
        _channels = activeCapture.channels;
        _savedPath = null;
      });
      _meterTimer = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) => unawaited(_pollInput()),
      );
    } catch (error) {
      if (capture != null) await capture.stop();
      if (writer != null) await writer.discard();
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _pollInput() async {
    final capture = _capture;
    if (capture == null || _polling) return;
    _polling = true;
    var stopAfterPoll = false;
    try {
      final samples = await capture.readFrames(maxFrames: 4096);
      if (!identical(capture, _capture)) return;
      if (samples.isNotEmpty) {
        final writer = _writer;
        if (writer == null) {
          throw const AudioRecordingUnavailable('Recording file is not available.');
        }
        await writer.append(samples);
      }
      if (!mounted || !identical(capture, _capture)) return;
      var peak = 0.0;
      var sumSquares = 0.0;
      for (final sample in samples) {
        final magnitude = sample.abs();
        if (magnitude > peak) peak = magnitude;
        sumSquares += sample * sample;
      }
      final rms = samples.isEmpty
          ? _rms * 0.82
          : math.sqrt(sumSquares / samples.length);
      final streamFailed = capture.hasError;
      setState(() {
        _peak = samples.isEmpty ? _peak * 0.82 : peak;
        _rms = rms;
        _capturedFrames += samples.length ~/ capture.channels;
        _droppedFrames = capture.droppedFrames;
        if (streamFailed) {
          _message = 'The input device reported an audio stream error. The take is being finalized.';
          _meterTimer?.cancel();
        }
      });
      stopAfterPoll = streamFailed;
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Recording stopped: $error');
      }
      _meterTimer?.cancel();
      stopAfterPoll = true;
    } finally {
      _polling = false;
    }
    if (stopAfterPoll && mounted) {
      unawaited(_stopRecording());
    }
  }

  Future<void> _stopRecording() async {
    if (_stopping) return;
    _stopping = true;
    try {
      _meterTimer?.cancel();
      _meterTimer = null;
      final capture = _capture;
      var paused = capture == null;
      String? warning;
      if (capture != null) {
        try {
          await capture.pause();
          paused = true;
        } catch (error) {
          warning = 'The input stream could not be paused cleanly: $error';
        }
      }
      while (_polling) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      _capture = null;
      final writer = _writer;
      _writer = null;
      String? path;
      try {
        if (capture != null && paused) {
          while (true) {
            final remaining = await capture.readFrames(maxFrames: 4096);
            if (remaining.isEmpty) break;
            if (writer != null) await writer.append(remaining);
            _capturedFrames += remaining.length ~/ capture.channels;
          }
        }
      } catch (error) {
        warning = 'Some buffered audio could not be saved: $error';
      } finally {
        if (capture != null) {
          _droppedFrames = capture.droppedFrames;
          await capture.stop();
        }
      }
      try {
        if (writer != null) path = await writer.finish();
      } catch (error) {
        warning = 'The recording could not be finalized: $error';
        if (writer != null) await writer.discard();
      }
      if (_droppedFrames > 0) {
        warning ??= 'Recording saved with $_droppedFrames dropped frames; this take may contain a short gap.';
      }
      if (capture != null && !paused) {
        warning ??= 'Only the samples already written were saved because the input stream could not pause.';
      }
      if (mounted) {
        setState(() {
          _peak = 0;
          _rms = 0;
          _savedPath = path;
          _message = path != null
              ? (warning ?? 'Recording saved successfully.')
              : (warning ?? 'No recording file was saved.');
        });
      }
    } finally {
      _stopping = false;
    }
  }

  Future<void> _playSavedTake() async {
    final path = _savedPath;
    if (path == null || _capture != null || _starting) return;
    await _stopPlayback();
    try {
      final bytes = await readAudioFile(path);
      final playback = await _engine.startPlayback(wavBytes: bytes);
      if (!mounted) {
        await playback.stop();
        return;
      }
      setState(() {
        _playback = playback;
        _playbackPosition = 0;
        _message = 'Playing saved WAV through the default audio output.';
      });
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => unawaited(_pollPlayback()),
      );
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _pollPlayback() async {
    final playback = _playback;
    if (playback == null) return;
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
          _message = failed
              ? 'The audio output device reported a playback error.'
              : 'Playback finished.';
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _playbackPosition = position);
    }
  }

  Future<void> _stopPlayback() async {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    final playback = _playback;
    _playback = null;
    if (playback != null) await playback.stop();
    if (mounted && playback != null) {
      setState(() => _playbackPosition = 0);
    }
  }

  String _formatPlaybackTime(int frames, int sampleRate) {
    if (sampleRate <= 0) return '00:00';
    final totalSeconds = frames ~/ sampleRate;
    return '${(totalSeconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(totalSeconds % 60).toString().padLeft(2, '0')}';
  }

  String get _elapsed {
    if (_sampleRate <= 0) return '00:00';
    final totalSeconds = _capturedFrames ~/ _sampleRate;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final listening = _capture != null;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 34),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RECORDING WORKSPACE',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AuraTheme.mint,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Voice Studio',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh microphone list',
                    onPressed: listening || _loadingDevices || _starting
                        ? null
                        : _refreshDevices,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AuraTheme.panel,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.mic_none_rounded, color: AuraTheme.mint),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Microphone input',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                        _StatusChip(label: listening ? 'RECORDING' : 'STOPPED'),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Input device',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: AuraTheme.muted,
                          ),
                    ),
                    const SizedBox(height: 8),
                    InputDecorator(
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: AuraTheme.panelLight,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 3),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(13),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _devices.any((device) => device.id == _selectedDeviceId)
                              ? _selectedDeviceId
                              : null,
                          hint: Text(_loadingDevices ? 'Finding microphones…' : 'Select an input'),
                          items: _devices
                              .map(
                                (device) => DropdownMenuItem(
                                  value: device.id,
                                  child: Text(
                                    device.isDefault ? '${device.name}  ·  Default' : device.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: listening
                              ? null
                              : (value) => setState(() => _selectedDeviceId = value),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            listening
                                ? '$_sampleRate Hz  ·  $_channels channel(s)'
                                : 'Device sample rate will be selected by the OS',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AuraTheme.muted,
                                ),
                          ),
                        ),
                        Text(
                          _elapsed,
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _InputLevelMeter(label: 'Peak', value: _peak),
                    const SizedBox(height: 13),
                    _InputLevelMeter(label: 'RMS', value: _rms),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _starting || listening || _devices.isEmpty
                                ? null
                                : _startRecording,
                            icon: _starting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.mic_rounded),
                            label: Text(_starting ? 'Starting…' : 'Start recording'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AuraTheme.mint,
                              foregroundColor: const Color(0xFF07151A),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        if (listening) ...[
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: _stopRecording,
                            icon: const Icon(Icons.stop_rounded),
                            label: const Text('Finish & save'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_message != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _message!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFFFC27A),
                              height: 1.45,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: AuraTheme.panelLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AuraTheme.mint, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Recording is saved locally as 24-bit PCM WAV in Documents / Aura Voice Studio / Recordings. Audio is not uploaded to a cloud service.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AuraTheme.muted,
                              height: 1.5,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              if (listening) ...[
                const SizedBox(height: 12),
                Text(
                  _droppedFrames == 0
                      ? 'Input buffer healthy  ·  $_capturedFrames frames written'
                      : 'Warning: $_droppedFrames frames dropped. This take may contain a gap.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _droppedFrames == 0
                            ? AuraTheme.muted
                            : const Color(0xFFFFC27A),
                      ),
                ),
              ],
              if (_savedPath != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AuraTheme.panel,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.check_circle_outline_rounded, color: AuraTheme.mint),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SelectableText(
                              _savedPath!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.white70,
                                    height: 1.45,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _playback == null
                                  ? 'WAV preview'
                                  : '${_formatPlaybackTime(_playbackPosition, _playback!.sampleRate)} / ${_formatPlaybackTime(_playback!.totalFrames, _playback!.sampleRate)}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AuraTheme.muted,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: listening || _starting ? null : _playSavedTake,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play'),
                          ),
                          if (_playback != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Stop preview',
                              onPressed: _stopPlayback,
                              icon: const Icon(Icons.stop_rounded),
                            ),
                          ],
                        ],
                      ),
                      if (_playback != null)
                        LinearProgressIndicator(
                          value: _playback!.totalFrames == 0
                              ? 0
                              : (_playbackPosition / _playback!.totalFrames)
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(4),
                          backgroundColor: AuraTheme.panelLight,
                          color: AuraTheme.mint,
                        ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
        ),
      ],
    );
  }
}

class _InputLevelMeter extends StatelessWidget {
  const _InputLevelMeter({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AuraTheme.muted,
                ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 11,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF111A2B)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: normalized,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AuraTheme.mint, Color(0xFFFFC27A)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 42,
          child: Text(
            '${(normalized * 100).round()}%',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white70,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ),
      ],
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final AudioLibraryService _library;
  late final AudioProjectStore _projects;
  late final AudioEngineService _engine;
  late final AudioWaveformService _waveforms;
  final TextEditingController _searchController = TextEditingController();
  final List<AudioLibraryRecording> _recordings = [];
  AudioPlaybackSession? _playback;
  Timer? _playbackTimer;
  String? _playingPath;
  String? _loadingPath;
  String? _waveformLoadingPath;
  String? _message;
  bool _loading = true;
  bool _pollingPlayback = false;
  String _sortBy = 'recent';

  @override
  void initState() {
    super.initState();
    _library = createAudioLibraryService();
    _projects = createAudioProjectStore();
    _engine = createAudioEngineService();
    _waveforms = createAudioWaveformService();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _playbackTimer?.cancel();
    final playback = _playback;
    _playback = null;
    if (playback != null) unawaited(playback.stop());
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }
    try {
      final items = await _library.listRecordings();
      if (!mounted) return;
      setState(() {
        _recordings
          ..clear()
          ..addAll(items);
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<AudioLibraryRecording> get _visibleRecordings {
    final query = _searchController.text.trim().toLowerCase();
    final items = _recordings
        .where((item) => item.name.toLowerCase().contains(query))
        .toList();
    switch (_sortBy) {
      case 'name':
        items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case 'longest':
        items.sort((a, b) => b.duration.compareTo(a.duration));
        break;
      case 'largest':
        items.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        break;
      default:
        items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
        break;
    }
    return items;
  }

  Future<void> _play(AudioLibraryRecording recording) async {
    if (_loadingPath != null) return;
    if (_playingPath == recording.path && _playback != null) {
      await _stopPlayback();
      return;
    }
    await _stopPlayback();
    if (!mounted) return;
    setState(() {
      _loadingPath = recording.path;
      _message = null;
    });
    try {
      final bytes = await readAudioFile(recording.path);
      final playback = await _engine.startPlayback(wavBytes: bytes);
      if (!mounted) {
        await playback.stop();
        return;
      }
      setState(() {
        _playback = playback;
        _playingPath = recording.path;
      });
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => unawaited(_pollPlayback()),
      );
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _loadingPath = null);
    }
  }

  Future<void> _pollPlayback() async {
    final playback = _playback;
    if (playback == null || _pollingPlayback) return;
    _pollingPlayback = true;
    try {
      final complete = playback.isComplete;
      final failed = playback.hasError;
      if (complete || failed) {
        _playbackTimer?.cancel();
        _playbackTimer = null;
        _playback = null;
        _playingPath = null;
        await playback.stop();
        if (mounted) {
          setState(() {
            _message = failed ? 'The output device reported a playback error.' : null;
          });
        }
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
    _playingPath = null;
    if (playback != null) await playback.stop();
    if (mounted) setState(() {});
  }

  Future<void> _showWaveform(AudioLibraryRecording recording) async {
    if (_waveformLoadingPath != null) return;
    setState(() {
      _waveformLoadingPath = recording.path;
      _message = null;
    });
    try {
      final waveform = await _waveforms.analyze(
        recording.path,
        peakCount: 320,
      );
      if (!mounted) return;
      setState(() => _waveformLoadingPath = null);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            recording.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  height: 132,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                  decoration: BoxDecoration(
                    color: AuraTheme.panel,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: CustomPaint(
                    painter: _WaveformPainter(waveform.peaks),
                    child: const SizedBox.expand(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${_durationLabel(waveform.duration)} · ${waveform.sampleRate} Hz · '
                  '${waveform.channels == 1 ? 'Mono' : 'Stereo'} · '
                  '${waveform.bitsPerSample}-bit PCM',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: AuraTheme.muted,
                      ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${waveform.frameCount} sample frames · '
                  '${waveform.peaks.length} peak buckets',
                  style: Theme.of(dialogContext).textTheme.labelSmall?.copyWith(
                        color: AuraTheme.muted,
                      ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_play(recording));
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play audio'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted && _waveformLoadingPath == recording.path) {
        setState(() => _waveformLoadingPath = null);
      }
    }
  }

  Future<void> _rename(AudioLibraryRecording recording) async {
    if (_playingPath == recording.path) await _stopPlayback();
    final controller = TextEditingController(text: recording.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename recording'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 90,
          decoration: const InputDecoration(
            labelText: 'Recording name',
            hintText: 'Enter a name',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save name'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final updated = await _library.renameRecording(recording, name);
      if (!mounted) return;
      final index = _recordings.indexWhere((item) => item.path == recording.path);
      setState(() {
        if (index >= 0) _recordings[index] = updated;
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _openSavedProjects() async {
    try {
      final projects = await _projects.listProjects();
      if (!mounted) return;
      if (projects.isEmpty) {
        setState(() => _message = 'No saved sessions yet. Open a recording in the editor and save a project.');
        return;
      }
      final selected = await showDialog<AudioProjectSummary>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Saved sessions'),
          content: SizedBox(
            width: 440,
            height: 380,
            child: ListView.separated(
              itemCount: projects.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final project = projects[index];
                final modified = project.modifiedAt.toLocal();
                final stamp = '${modified.day.toString().padLeft(2, '0')}/'
                    '${modified.month.toString().padLeft(2, '0')}/'
                    '${modified.year}';
                return ListTile(
                  leading: const Icon(Icons.audio_file_rounded, color: AuraTheme.mint),
                  title: Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${project.trackCount} tracks · ${project.sampleRate} Hz · $stamp',
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(project),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final session = await _projects.load(selected.path);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AudioEditorPage(
            initialSession: session,
            initialProjectPath: selected.path,
          ),
        ),
      );
      if (mounted) await _refresh();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  Future<void> _openEditor(AudioLibraryRecording recording) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AudioEditorPage(initialRecording: recording),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _delete(AudioLibraryRecording recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(
          '“${recording.name}” will be permanently deleted from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB94B55),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_playingPath == recording.path) await _stopPlayback();
    try {
      await _library.deleteRecording(recording);
      if (!mounted) return;
      setState(() {
        _recordings.removeWhere((item) => item.path == recording.path);
        _message = 'Recording deleted from this device.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    }
  }

  String _durationLabel(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _dateLabel(DateTime date) {
    final local = date.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year.toString();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day/$month/$year · $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleRecordings;
    final totalBytes = _recordings.fold<int>(
      0,
      (total, item) => total + item.sizeBytes,
    );
    final totalDuration = _recordings.fold<Duration>(
      Duration.zero,
      (total, item) => total + item.duration,
    );

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 34),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUR AUDIO',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: AuraTheme.mint,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Audio Library',
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Open saved sessions',
                      onPressed: _loading ? null : _openSavedProjects,
                      icon: const Icon(Icons.folder_open_rounded),
                    ),
                    IconButton(
                      tooltip: 'Refresh library',
                      onPressed: _loading ? null : _refresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AuraTheme.panel,
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _LibraryStat(
                          label: 'RECORDINGS',
                          value: _recordings.length.toString(),
                          icon: Icons.library_music_rounded,
                        ),
                      ),
                      Expanded(
                        child: _LibraryStat(
                          label: 'TOTAL TIME',
                          value: _durationLabel(totalDuration),
                          icon: Icons.schedule_rounded,
                        ),
                      ),
                      Expanded(
                        child: _LibraryStat(
                          label: 'STORAGE',
                          value: _sizeLabel(totalBytes),
                          icon: Icons.storage_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search recordings…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    filled: true,
                    fillColor: AuraTheme.panel,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${visible.length} of ${_recordings.length} recordings',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AuraTheme.muted,
                            ),
                      ),
                    ),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _sortBy,
                        dropdownColor: AuraTheme.panel,
                        items: const [
                          DropdownMenuItem(value: 'recent', child: Text('Newest first')),
                          DropdownMenuItem(value: 'name', child: Text('Name')),
                          DropdownMenuItem(value: 'longest', child: Text('Longest')),
                          DropdownMenuItem(value: 'largest', child: Text('Largest')),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _sortBy = value);
                        },
                      ),
                    ),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _message!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFFFC27A),
                          height: 1.4,
                        ),
                  ),
                ],
                if (_loading) ...[
                  const SizedBox(height: 30),
                  const Center(child: CircularProgressIndicator()),
                ] else if (_recordings.isEmpty) ...[
                  const SizedBox(height: 34),
                  _LibraryEmptyState(directoryPath: _library.directoryPath),
                ] else if (visible.isEmpty) ...[
                  const SizedBox(height: 32),
                  const Center(child: Text('No recordings match this search.')),
                ] else ...[
                  const SizedBox(height: 8),
                  for (final recording in visible)
                    _RecordingCard(
                      recording: recording,
                      durationLabel: _durationLabel(recording.duration),
                      sizeLabel: _sizeLabel(recording.sizeBytes),
                      dateLabel: _dateLabel(recording.modifiedAt),
                      playing: _playingPath == recording.path,
                      loading: _loadingPath == recording.path,
                      waveformLoading: _waveformLoadingPath == recording.path,
                      onPlay: () => _play(recording),
                      onWaveform: () => _showWaveform(recording),
                      onEdit: () => _openEditor(recording),
                      onRename: () => _rename(recording),
                      onDelete: () => _delete(recording),
                    ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Only local WAV files in this device’s Aura Voice Studio Recordings folder appear here.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AuraTheme.muted,
                        height: 1.5,
                      ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryStat extends StatelessWidget {
  const _LibraryStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AuraTheme.mint, size: 18),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AuraTheme.muted,
                  letterSpacing: 0.7,
                ),
          ),
        ],
      );
}

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({
    required this.recording,
    required this.durationLabel,
    required this.sizeLabel,
    required this.dateLabel,
    required this.playing,
    required this.loading,
    required this.waveformLoading,
    required this.onPlay,
    required this.onWaveform,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
  });

  final AudioLibraryRecording recording;
  final String durationLabel;
  final String sizeLabel;
  final String dateLabel;
  final bool playing;
  final bool loading;
  final bool waveformLoading;
  final VoidCallback onPlay;
  final VoidCallback onWaveform;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AuraTheme.panel,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: playing
                ? AuraTheme.mint.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.055),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AuraTheme.mint.withValues(alpha: 0.11),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                playing ? Icons.graphic_eq_rounded : Icons.audio_file_rounded,
                color: AuraTheme.mint,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    recording.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$durationLabel · ${recording.sampleRate} Hz · ${recording.channels == 1 ? 'Mono' : 'Stereo'} · ${recording.bitsPerSample}-bit',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AuraTheme.muted,
                        ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$dateLabel · $sizeLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AuraTheme.muted,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Show waveform',
              onPressed: waveformLoading ? null : onWaveform,
              icon: waveformLoading
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.graphic_eq_rounded, color: Colors.white70),
            ),
            IconButton(
              tooltip: playing ? 'Stop playback' : 'Play recording',
              onPressed: loading ? null : onPlay,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      playing ? Icons.stop_circle_rounded : Icons.play_circle_fill_rounded,
                      color: AuraTheme.mint,
                      size: 30,
                    ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Recording actions',
              onSelected: (value) {
                if (value == 'editor') onEdit();
                if (value == 'rename') onRename();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'editor',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.tune_rounded),
                    title: Text('Open in editor'),
                  ),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Rename'),
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('Delete'),
                  ),
                ),
              ],
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            ),
          ],
        ),
      );
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter(this.peaks);

  final List<double> peaks;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.isEmpty) return;
    final centerY = size.height / 2;
    final slotWidth = size.width / peaks.length;
    final paint = Paint()
      ..color = AuraTheme.mint
      ..strokeWidth = math.max(1.0, slotWidth * 0.64).toDouble()
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < peaks.length; index++) {
      final peak = peaks[index].clamp(0.0, 1.0).toDouble();
      final halfHeight =
          math.max(1.0, peak * (size.height * 0.46)).toDouble();
      final x = (index + 0.5) * slotWidth;
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      !identical(oldDelegate.peaks, peaks);
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({required this.directoryPath});

  final String directoryPath;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: AuraTheme.panel,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
        ),
        child: Column(
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: AuraTheme.mint.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.library_music_rounded,
                size: 30,
                color: AuraTheme.mint,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Your library is empty',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 7),
            Text(
              'Record a take in Voice Studio. Saved WAV files will appear here automatically.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AuraTheme.muted,
                    height: 1.5,
                  ),
            ),
            const SizedBox(height: 14),
            SelectableText(
              directoryPath,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white54,
                    height: 1.5,
                  ),
            ),
          ],
        ),
      );
}

class _ComingSoonPage extends StatelessWidget {
  const _ComingSoonPage({required this.icon, required this.title, required this.description});
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 76, height: 76,
            decoration: BoxDecoration(color: AuraTheme.panelLight, borderRadius: BorderRadius.circular(24)),
            child: Icon(icon, size: 36, color: AuraTheme.mint)),
          const SizedBox(height: 22),
          Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(description, textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AuraTheme.muted, height: 1.6)),
          const SizedBox(height: 18),
          const _StatusChip(label: 'IN DEVELOPMENT'),
        ]),
      ),
    ),
  );
}
