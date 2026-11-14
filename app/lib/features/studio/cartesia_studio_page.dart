import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../core/services/api_client.dart';
import '../../core/theme/aura_theme.dart';

class CartesiaStudioPage extends StatefulWidget {
  const CartesiaStudioPage({super.key});

  @override
  State<CartesiaStudioPage> createState() => _CartesiaStudioPageState();
}

class _CartesiaStudioPageState extends State<CartesiaStudioPage> {
  final _api = const ApiClient();
  final _textController = TextEditingController(
    text: 'আসসালামু আলাইকুম। Aura Voice AI-তে স্বাগতম।',
  );
  final _player = AudioPlayer();

  late final StreamSubscription<PlayerState> _playerSubscription;
  String _language = 'bn';
  String? _selectedVoiceId;
  double _speed = 1.0;
  List<Map<String, dynamic>> _voices = [];
  bool _loadingVoices = false;
  bool _generating = false;
  bool _playing = false;
  String? _error;
  String? _notice;
  Uint8List? _audioBytes;

  @override
  void initState() {
    super.initState();
    _playerSubscription = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playing = state == PlayerState.playing);
      }
    });
    _loadVoices();
  }

  @override
  void dispose() {
    _playerSubscription.cancel();
    _player.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    setState(() {
      _loadingVoices = true;
      _error = null;
      _notice = null;
      _selectedVoiceId = null;
    });
    try {
      final voices = await _api.listVoices(language: _language);
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _loadingVoices = false;
        if (voices.isEmpty) {
          _notice = 'No voices were returned for this language. Choose another language or configure a compatible voice ID on the backend.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _voices = [];
        _loadingVoices = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _generate() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _generating) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _generating = true;
      _error = null;
      _notice = null;
      _audioBytes = null;
    });

    try {
      final bytes = await _api.generateSpeech(
        text: text,
        language: _language,
        speed: _speed,
        voiceId: _selectedVoiceId,
      );
      if (!mounted) return;
      setState(() {
        _audioBytes = bytes;
        _generating = false;
        _notice = 'Audio generated successfully with Cartesia Sonic.';
      });
      await _player.play(BytesSource(bytes));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _playAgain() async {
    final bytes = _audioBytes;
    if (bytes == null) return;
    try {
      await _player.play(BytesSource(bytes));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Audio playback failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 30),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: AuraTheme.mint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Icon(Icons.graphic_eq_rounded,
                        color: AuraTheme.mint, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Voice Studio',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            )),
                        const SizedBox(height: 3),
                        Text('Powered by Cartesia Sonic',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AuraTheme.muted,
                            )),
                      ],
                    ),
                  ),
                  _EngineBadge(
                    label: _loadingVoices ? 'CONNECTING' : 'SONIC TTS',
                    active: !_loadingVoices && _error == null,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('01  ·  SCRIPT',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: AuraTheme.mint,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w800,
                        )),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _textController,
                      minLines: 6,
                      maxLines: 12,
                      maxLength: 5000,
                      onChanged: (_) => setState(() {}),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Write or paste the words you want to speak...',
                        alignLabelWithHint: true,
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Maximum 5,000 characters per generation.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AuraTheme.muted,
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('02  ·  VOICE SETTINGS',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: AuraTheme.mint,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w800,
                        )),
                    const SizedBox(height: 16),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final stacked = constraints.maxWidth < 560;
                        final languageField = _languageDropdown();
                        final voiceField = _voiceDropdown();
                        if (stacked) {
                          return Column(
                            children: [
                              languageField,
                              const SizedBox(height: 14),
                              voiceField,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: languageField),
                            const SizedBox(width: 14),
                            Expanded(child: voiceField),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Text('Speaking speed',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            )),
                        const Spacer(),
                        Text('${_speed.toStringAsFixed(1)}×',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: AuraTheme.mint,
                              fontWeight: FontWeight.w800,
                            )),
                      ],
                    ),
                    Slider(
                      value: _speed,
                      min: 0.6,
                      max: 1.5,
                      divisions: 9,
                      activeColor: AuraTheme.mint,
                      onChanged: (value) => setState(() => _speed = value),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Slower', style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
                        Text('Natural', style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
                        Text('Faster', style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_error != null) ...[
                _MessagePanel(message: _error!, isError: true),
                const SizedBox(height: 12),
              ],
              if (_notice != null) ...[
                _MessagePanel(message: _notice!, isError: false),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _generating || _textController.text.trim().isEmpty
                      ? null
                      : _generate,
                  icon: _generating
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF07151A),
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded),
                  label: Text(_generating ? 'Generating voice...' : 'Generate speech'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AuraTheme.mint,
                    foregroundColor: const Color(0xFF07151A),
                    disabledBackgroundColor: AuraTheme.mint.withValues(alpha: 0.35),
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (_audioBytes != null)
                _Panel(
                  child: Row(
                    children: [
                      Container(
                        height: 44,
                        width: 44,
                        decoration: BoxDecoration(
                          color: AuraTheme.mint.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.audio_file_rounded, color: AuraTheme.mint),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Your generated audio',
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                            const SizedBox(height: 3),
                            Text('WAV · 44.1 kHz · ${(_audioBytes!.length / 1024).toStringAsFixed(0)} KB',
                                style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted)),
                          ],
                        ),
                      ),
                      IconButton.filled(
                        tooltip: 'Play again',
                        onPressed: _playAgain,
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Your Cartesia API key stays on the backend. It is not stored in this Flutter app.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AuraTheme.muted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _languageDropdown() {
    return DropdownButtonFormField<String>(
      value: _language,
      decoration: const InputDecoration(
        labelText: 'Language',
        filled: true,
      ),
      items: const [
        DropdownMenuItem(value: 'bn', child: Text('বাংলা · Bangla')),
        DropdownMenuItem(value: 'en', child: Text('English')),
        DropdownMenuItem(value: 'ar', child: Text('العربية · Arabic')),
        DropdownMenuItem(value: 'hi', child: Text('हिन्दी · Hindi')),
      ],
      onChanged: (value) {
        if (value == null || value == _language) return;
        setState(() => _language = value);
        _loadVoices();
      },
    );
  }

  Widget _voiceDropdown() {
    return DropdownButtonFormField<String>(
      value: _selectedVoiceId,
      decoration: InputDecoration(
        labelText: 'Cartesia voice',
        filled: true,
        suffixIcon: _loadingVoices
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Refresh voices',
                onPressed: _loadVoices,
                icon: const Icon(Icons.refresh_rounded),
              ),
      ),
      hint: Text(_voices.isEmpty ? 'No voice found for this language' : 'Choose a voice'),
      items: _voices
          .map(
            (voice) => DropdownMenuItem<String>(
              value: voice['id']?.toString(),
              child: Text(
                voice['name']?.toString() ?? 'Cartesia voice',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: _voices.isEmpty
          ? null
          : (value) => setState(() => _selectedVoiceId = value),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AuraTheme.panel,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: child,
      );
}

class _EngineBadge extends StatelessWidget {
  const _EngineBadge({required this.label, required this.active});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: (active ? AuraTheme.mint : AuraTheme.violet).withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: active ? AuraTheme.mint : AuraTheme.violet,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
        ),
      );
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message, required this.isError});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: (isError ? Colors.redAccent : AuraTheme.mint).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: (isError ? Colors.redAccent : AuraTheme.mint).withValues(alpha: 0.22),
          ),
        ),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isError ? Colors.redAccent.shade100 : AuraTheme.mint,
                height: 1.5,
              ),
        ),
      );
}
