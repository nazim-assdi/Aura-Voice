import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:material_ui/material_ui.dart';

import '../../core/services/api_client.dart';
import '../../core/services/audio_engine_service.dart';
import '../../core/theme/aura_theme.dart';

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
                  _FeatureData(Icons.record_voice_over_rounded, 'Record Booth', 'Capture clean takes', AuraTheme.mint),
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
                'Foundation preview · Audio engine, recording and speech providers are not connected yet. Planned tools remain clearly marked until their processing engines pass tests.',
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
  const _FeatureData(this.icon, this.title, this.subtitle, this.accent);
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
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
      Text('PLANNED', style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AuraTheme.muted, letterSpacing: 1.2)),
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
  Timer? _meterTimer;
  String? _selectedDeviceId;
  String? _message;
  bool _loadingDevices = true;
  bool _starting = false;
  bool _polling = false;
  double _peak = 0;
  double _rms = 0;
  int _sampleRate = 0;
  int _channels = 0;
  int _capturedFrames = 0;
  int _droppedFrames = 0;

  @override
  void initState() {
    super.initState();
    _engine = createAudioEngineService();
    unawaited(_refreshDevices());
  }

  @override
  void dispose() {
    _meterTimer?.cancel();
    final capture = _capture;
    _capture = null;
    if (capture != null) {
      unawaited(capture.stop());
    }
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
          _selectedDeviceId = _devices
              .where((device) => device.isDefault)
              .firstOrNull
              ?.id ??
              (_devices.isEmpty ? null : _devices.first.id);
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

  Future<void> _startInputCheck() async {
    if (_starting || _capture != null) return;
    setState(() {
      _starting = true;
      _message = null;
      _peak = 0;
      _rms = 0;
      _capturedFrames = 0;
      _droppedFrames = 0;
    });
    try {
      final capture = await _engine.startCapture(
        deviceId: _selectedDeviceId,
        bufferMilliseconds: 1000,
      );
      if (!mounted) {
        await capture.stop();
        return;
      }
      setState(() {
        _capture = capture;
        _sampleRate = capture.sampleRate;
        _channels = capture.channels;
      });
      _meterTimer = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) => unawaited(_pollInput()),
      );
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _pollInput() async {
    final capture = _capture;
    if (capture == null || _polling) return;
    _polling = true;
    try {
      final samples = await capture.readFrames(maxFrames: 4096);
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
          : _sqrt(sumSquares / samples.length);
      setState(() {
        _peak = samples.isEmpty ? _peak * 0.82 : peak;
        _rms = rms;
        _capturedFrames += samples.length ~/ capture.channels;
        _droppedFrames = capture.droppedFrames;
        if (capture.hasError) {
          _message = 'The input device reported an audio stream error. Stop and reconnect the microphone.';
          _meterTimer?.cancel();
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
        _meterTimer?.cancel();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _stopInputCheck() async {
    _meterTimer?.cancel();
    _meterTimer = null;
    final capture = _capture;
    _capture = null;
    if (capture != null) await capture.stop();
    if (mounted) {
      setState(() {
        _peak = 0;
        _rms = 0;
      });
    }
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
                    onPressed: listening || _loadingDevices ? null : _refreshDevices,
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
                        _StatusChip(label: listening ? 'INPUT ACTIVE' : 'STOPPED'),
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
                                : _startInputCheck,
                            icon: _starting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.mic_rounded),
                            label: Text(_starting ? 'Starting…' : 'Start input check'),
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
                            onPressed: _stopInputCheck,
                            icon: const Icon(Icons.stop_rounded),
                            label: const Text('Stop'),
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
                        'Live input check only: microphone samples are measured for the meters and then discarded. No recording file is saved yet.',
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
                      ? 'Input buffer healthy  ·  $_capturedFrames frames read'
                      : 'Warning: $_droppedFrames frames dropped. The input buffer was not drained fast enough.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _droppedFrames == 0
                            ? AuraTheme.muted
                            : const Color(0xFFFFC27A),
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

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});
  @override
  Widget build(BuildContext context) => const _ComingSoonPage(
    icon: Icons.library_music_rounded, title: 'Audio Library',
    description: 'Your recordings, generated speech, voice projects and final audio exports will appear here when local project storage and secure library management are implemented.',
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


double _sqrt(double value) {
  if (value <= 0) return 0;
  var estimate = value < 1 ? 1.0 : value;
  for (var i = 0; i < 12; i++) {
    estimate = (estimate + value / estimate) / 2;
  }
  return estimate;
}
