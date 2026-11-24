import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/services/api_client.dart';
import '../../core/services/local_ai_server.dart';
import '../../core/theme/aura_theme.dart';

class AiVoiceStudioPage extends StatefulWidget {
  const AiVoiceStudioPage({super.key});

  @override
  State<AiVoiceStudioPage> createState() => _AiVoiceStudioPageState();
}

class _AiVoiceStudioPageState extends State<AiVoiceStudioPage> {
  static const _languages = <String, String>{
    'bn-BD': 'Bengali · Bangladesh',
    'en-US': 'English · United States',
    'en-GB': 'English · United Kingdom',
    'hi-IN': 'Hindi · India',
    'ur-PK': 'Urdu · Pakistan',
    'ar-SA': 'Arabic · Saudi Arabia',
  };

  final _api = const ApiClient();
  static const _elevenLabsKeyName = 'aura_elevenlabs_api_key';
  static const _cartesiaKeyName = 'aura_cartesia_api_key';
  static const _providerKeyName = 'aura_speech_provider';

  final _scriptController = TextEditingController();
  final _player = AudioPlayer();
  final _secureStorage = FlutterSecureStorage();

  String? _baseUrl;
  String _speechProvider = 'edge-tts';
  String _delivery = 'natural';

  bool get _premiumEngine =>
      _speechProvider == 'elevenlabs' || _speechProvider == 'cartesia';

  List<SpeechVoice> _voices = const [];
  String _locale = 'bn-BD';
  String? _selectedVoice;
  Uint8List? _audioBytes;
  bool _checking = false;
  bool _connected = false;
  bool _speechReady = false;
  bool _loadingVoices = false;
  bool _generating = false;
  bool _playing = false;
  int _rate = 0;
  int _pitch = 0;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playing = state == PlayerState.playing);
      }
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _scriptController.dispose();
    unawaited(_player.dispose());
    unawaited(LocalAiServer.instance.stop());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final configuredUrl = await _api.loadBaseUrl();
      final isDefaultUrl = configuredUrl == ApiClient.defaultBaseUrl;
      _baseUrl = defaultTargetPlatform == TargetPlatform.android && isDefaultUrl
          ? 'http://10.0.2.2:8000'
          : configuredUrl;
      if (!mounted) {
        return;
      }
      await _connect();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _connect() async {
    if (_checking) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _error = null;
      _message = 'Checking the AI service and available voices…';
      _connected = false;
      _speechReady = false;
    });
    try {
      final url = _baseUrl ?? ApiClient.defaultBaseUrl;
      final isBundledWindows =
          defaultTargetPlatform == TargetPlatform.windows &&
          url == ApiClient.defaultBaseUrl;
      final preferredProvider = isBundledWindows
          ? (await _secureStorage.read(key: _providerKeyName) ?? 'edge').trim()
          : 'edge';
      final elevenLabsKey = isBundledWindows && preferredProvider == 'elevenlabs'
          ? (await _secureStorage.read(key: _elevenLabsKeyName) ?? '').trim()
          : '';
      final cartesiaKey = isBundledWindows && preferredProvider == 'cartesia'
          ? (await _secureStorage.read(key: _cartesiaKeyName) ?? '').trim()
          : '';

      if (isBundledWindows) {
        if (preferredProvider == 'elevenlabs' && elevenLabsKey.isEmpty) {
          throw const ApiClientException('Add your ElevenLabs API key in Voice Engine settings.');
        }
        if (preferredProvider == 'cartesia' && cartesiaKey.isEmpty) {
          throw const ApiClientException('Add your Cartesia API key in Voice Engine settings.');
        }
        if (mounted) {
          setState(() => _message = 'Starting the local voice engine…');
        }
        final started = await LocalAiServer.instance.ensureRunning(
          baseUrl: url,
          speechProvider: preferredProvider,
          elevenLabsApiKey: elevenLabsKey,
          cartesiaApiKey: cartesiaKey,
        );
        if (!started) {
          throw ApiClientException(
            preferredProvider == 'edge'
                ? 'Could not start the bundled local voice engine. Reinstall Aura Voice Studio and try again.'
                : 'Could not start the selected premium voice engine. Close any other Aura Voice server and reconnect.',
          );
        }
      }

      final health = await _api.health(baseUrl: url);
      if (health['ok'] != true) {
        throw const ApiClientException('The voice engine did not report healthy.');
      }
      if (health['speech_ready'] != true) {
        throw const ApiClientException(
          'The speech engine is online, but no provider is ready. Check your API key or use the standard engine.',
        );
      }
      final providerName = health['speech_provider'] as String? ?? 'edge-tts';
      final expectedProvider = preferredProvider == 'edge' ? 'edge-tts' : preferredProvider;
      if (isBundledWindows && providerName != expectedProvider) {
        throw const ApiClientException(
          'The selected voice engine could not be applied. Restart Aura Voice Studio and reconnect.',
        );
      }
      await _loadVoices(baseUrl: url, updateBusy: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _speechProvider = providerName;
        _connected = true;
        _speechReady = _voices.isNotEmpty;
        _message = _voices.isNotEmpty
            ? (_speechProvider == 'cartesia'
                ? 'Cartesia Sonic 3.6 is ready. Choose a voice and delivery style.'
                : _speechProvider == 'elevenlabs'
                    ? 'ElevenLabs v4 is ready. Choose a voice and delivery style.'
                    : 'Standard neural speech is ready. Choose a voice and generate a sample.')
            : 'The voice engine is online, but no voices were returned for this language.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connected = false;
        _speechReady = false;
        _error = error.toString();
        _message = 'Voice engine is not ready. Check your internet connection or premium key.';
      });
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _loadVoices({String? baseUrl, bool updateBusy = true}) async {
    if (updateBusy && mounted) {
      setState(() {
        _loadingVoices = true;
        _error = null;
      });
    }
    try {
      final voices = await _api.fetchVoices(
        baseUrl: baseUrl,
        locale: _locale,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _voices = voices;
        if (!_voices.any((voice) => voice.id == _selectedVoice)) {
          _selectedVoice = voices.isEmpty ? null : voices.first.id;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
      rethrow;
    } finally {
      if (updateBusy && mounted) {
        setState(() => _loadingVoices = false);
      }
    }
  }

  Future<void> _changeLanguage(String? value) async {
    if (value == null || value == _locale) {
      return;
    }
    setState(() {
      _locale = value;
      _selectedVoice = null;
      _voices = const [];
      _speechReady = false;
    });
    if (_connected) {
      try {
        await _loadVoices();
        if (mounted) {
          setState(() => _speechReady = _voices.isNotEmpty);
        }
      } catch (_) {
        // Error is displayed by _loadVoices.
      }
    }
  }

  Future<void> _generate() async {
    final script = _scriptController.text.trim();
    if (script.isEmpty) {
      setState(() => _error = 'Write or paste a script before generating speech.');
      return;
    }
    if (script.length > 5000) {
      setState(() => _error = 'The script is limited to 5,000 characters.');
      return;
    }
    if (_speechProvider == 'elevenlabs' && script.length > 2000) {
      setState(() => _error = 'ElevenLabs v4 dialogue supports up to 2,000 characters per request. Shorten the script or use the standard engine.');
      return;
    }
    if (_selectedVoice == null) {
      setState(() => _error = 'Select an available neural voice first.');
      return;
    }
    if (!_speechReady) {
      await _connect();
      if (!_speechReady || !mounted) {
        return;
      }
    }

    FocusScope.of(context).unfocus();
    await _player.stop();
    setState(() {
      _generating = true;
      _playing = false;
      _audioBytes = null;
      _error = null;
      _message = _speechProvider == 'cartesia'
          ? 'Generating expressive speech with Cartesia Sonic 3.6…'
          : _speechProvider == 'elevenlabs'
              ? 'Generating expressive speech with ElevenLabs v4…'
              : 'Generating neural speech…';
    });
    try {
      final audio = await _api.generateSpeech(
        baseUrl: _baseUrl ?? ApiClient.defaultBaseUrl,
        text: script,
        voice: _selectedVoice!,
        language: _locale,
        rate: _rate,
        pitch: _pitch,
        delivery: _delivery,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _audioBytes = audio;
        _message = _premiumEngine
            ? 'Premium speech generated. Preview it or save the MP3.'
            : 'Speech generated successfully. Preview it or save the MP3.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _message = 'Generation failed. Your script is still here; retry when connected.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }

  Future<void> _playPreview() async {
    final bytes = _audioBytes;
    if (bytes == null) {
      return;
    }
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not play the preview: $error');
      }
    }
  }

  Future<void> _saveMp3() async {
    final bytes = _audioBytes;
    if (bytes == null) {
      return;
    }
    final safeName = DateTime.now().toIso8601String().replaceAll(':', '-');
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save generated Aura Voice audio',
        fileName: 'Aura-Voice-$safeName.mp3',
        bytes: bytes,
        mimeType: 'audio/mpeg',
        type: FileType.custom,
        allowedExtensions: const ['mp3'],
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _message = saved == null ? 'Save cancelled.' : 'MP3 saved successfully.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'MP3 save failed: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final selectedVoice = _voices.where((voice) => voice.id == _selectedVoice);
    final selectedLabel =
        selectedVoice.isEmpty ? 'No voice selected' : selectedVoice.first.name;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(isWide ? 32 : 18, 24, isWide ? 32 : 18, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AuraTheme.mint, AuraTheme.violet],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.graphic_eq_rounded,
                      color: Color(0xFF07151A),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI Voice Studio',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.7,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Natural neural speech · multilingual · MP3',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AuraTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ConnectionBadge(ready: _speechReady, checking: _checking),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF193C49),
                      Color(0xFF25294A),
                      Color(0xFF171C31),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FROM SCRIPT TO SOUND',
                      style: TextStyle(
                        color: AuraTheme.mint,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Give your words\na natural voice.',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Generate speech with online neural voices. Preview the result and save it as an MP3.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 820;
                  final script = _scriptEditor(context);
                  final settings = _voiceSettings(context, selectedLabel);
                  if (!wide) {
                    return Column(
                      children: [
                        script,
                        const SizedBox(height: 16),
                        settings,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: script),
                      const SizedBox(width: 16),
                      Expanded(flex: 5, child: settings),
                    ],
                  );
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                _MessagePanel(message: _error!, isError: true),
              ],
              if (_message != null) ...[
                const SizedBox(height: 10),
                _MessagePanel(message: _message!, isError: false),
              ],
              if (_audioBytes != null) ...[
                const SizedBox(height: 16),
                _previewPanel(context),
              ],
              const SizedBox(height: 22),
              _connectionSettings(context),
              const SizedBox(height: 16),
              Text(
                'The voice engine connects automatically. Its backend address is hidden from the workspace. Premium voice generation uses your own ElevenLabs account and consumes its available credits.',
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

  Widget _scriptEditor(BuildContext context) {
    final theme = Theme.of(context);
    return _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.article_outlined, color: AuraTheme.mint),
              const SizedBox(width: 9),
              Text('Your script', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                '${_scriptController.text.length}/5000',
                style: theme.textTheme.labelSmall?.copyWith(color: AuraTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _scriptController,
            minLines: 10,
            maxLines: 16,
            maxLength: 5000,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Type or paste your script here…\n\nবাংলা, English, Hindi, Urdu or Arabic.',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: _scriptController.text.isEmpty
                    ? null
                    : () => setState(_scriptController.clear),
                icon: const Icon(Icons.backspace_outlined, size: 17),
                label: const Text('Clear'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _generating || _checking ? null : _generate,
                icon: _generating
                    ? const SizedBox(
                        height: 17,
                        width: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(_generating ? 'Generating…' : 'Generate voice'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _voiceSettings(BuildContext context, String selectedLabel) {
    final theme = Theme.of(context);
    return _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 14),
          const _FieldLabel('LANGUAGE'),
          const SizedBox(height: 7),
          DropdownButtonFormField<String>(
            initialValue: _locale,
            isExpanded: true,
            items: _languages.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: _changeLanguage,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.language_rounded),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const _FieldLabel('NEURAL VOICE'),
              const Spacer(),
              if (_loadingVoices)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 7),
          DropdownButtonFormField<String>(
            initialValue: _voices.any((voice) => voice.id == _selectedVoice)
                ? _selectedVoice
                : null,
            isExpanded: true,
            items: _voices
                .map(
                  (voice) => DropdownMenuItem(
                    value: voice.id,
                    child: Text(
                      '${voice.name} · ${voice.gender}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _loadingVoices
                ? null
                : (value) => setState(() => _selectedVoice = value),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.record_voice_over_rounded),
              hintText: _voices.isEmpty ? 'Connect to load voices' : null,
            ),
          ),
          if (_premiumEngine) ...[
            const SizedBox(height: 16),
            const _FieldLabel('SPEAKING STYLE'),
            const SizedBox(height: 7),
            DropdownButtonFormField<String>(
              initialValue: _delivery,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'natural', child: Text('Natural conversation')),
                DropdownMenuItem(value: 'warm', child: Text('Warm and friendly')),
                DropdownMenuItem(value: 'storytelling', child: Text('Expressive storytelling')),
                DropdownMenuItem(value: 'energetic', child: Text('Energetic delivery')),
                DropdownMenuItem(value: 'calm', child: Text('Calm and gentle')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _delivery = value);
              },
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.tune_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'ElevenLabs v4 uses expressive delivery cues while keeping your selected voice consistent.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AuraTheme.muted,
                height: 1.4,
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            _SliderSetting(
              label: 'Speech rate',
              value: _rate.toDouble(),
              min: -30,
              max: 30,
              valueText: _rate == 0 ? 'Normal' : '${_rate > 0 ? '+' : ''}$_rate%',
              onChanged: (value) => setState(() => _rate = value.round()),
            ),
            const SizedBox(height: 8),
            _SliderSetting(
              label: 'Pitch',
              value: _pitch.toDouble(),
              min: -30,
              max: 30,
              valueText: _pitch == 0 ? 'Normal' : '${_pitch > 0 ? '+' : ''}$_pitch Hz',
              onChanged: (value) => setState(() => _pitch = value.round()),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            selectedLabel,
            style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _connected && !_loadingVoices && !_generating
                ? () => _loadVoices()
                : null,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Refresh voices'),
          ),
        ],
      ),
    );
  }

  Widget _previewPanel(BuildContext context) {
    final theme = Theme.of(context);
    return _StudioCard(
      child: Row(
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: AuraTheme.mint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(
              Icons.multitrack_audio_rounded,
              color: AuraTheme.mint,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Generated speech', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '${(_audioBytes!.length / 1024).toStringAsFixed(1)} KB · MP3',
                  style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: _playing ? 'Pause preview' : 'Play preview',
            onPressed: _playPreview,
            icon: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Save MP3',
            onPressed: _saveMp3,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
    );
  }

  Widget _connectionSettings(BuildContext context) {
    final theme = Theme.of(context);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    return _StudioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq_rounded, color: AuraTheme.violet),
              const SizedBox(width: 9),
              Expanded(child: Text('Voice engine', style: theme.textTheme.titleSmall)),
              Text(
                _connected ? 'CONNECTED' : 'NOT CONNECTED',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _connected ? AuraTheme.mint : const Color(0xFFFFB6A4),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _premiumEngine
                ? (_speechProvider == 'cartesia'
                    ? 'Cartesia Sonic 3.6 · expressive natural speech'
                    : 'ElevenLabs v4 · expressive, lifelike speech')
                : 'Standard neural voice · automatic connection',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70, height: 1.45),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _checking || _generating ? null : _connect,
                icon: _checking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                label: Text(_checking ? 'Connecting…' : 'Reconnect'),
              ),
              OutlinedButton.icon(
                onPressed: _checking || _generating ? null : _openPremiumSetup,
                icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(_premiumEngine ? 'Premium voice settings' : 'Choose voice engine'),
              ),
            ],
          ),
          if (!isWindows) ...[
            const SizedBox(height: 9),
            Text(
              'Premium key setup is currently available in the Windows desktop app. Other platforms can use a server configured by the administrator.',
              style: theme.textTheme.bodySmall?.copyWith(color: AuraTheme.muted, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openPremiumSetup() async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      setState(() => _error = 'API key setup is currently available in the Windows desktop app.');
      return;
    }

    String selectedProvider =
        await _secureStorage.read(key: _providerKeyName) ?? 'edge';
    final controller = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Choose Aura Voice Engine'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selectedProvider,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'edge', child: Text('Standard Neural Voice · Free')),
                  DropdownMenuItem(value: 'elevenlabs', child: Text('ElevenLabs v4 · Premium')),
                  DropdownMenuItem(value: 'cartesia', child: Text('Cartesia Sonic 3.6 · Premium')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => selectedProvider = value);
                    controller.clear();
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Speech provider',
                  prefixIcon: Icon(Icons.graphic_eq_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              if (selectedProvider != 'edge') ...[
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: selectedProvider == 'cartesia'
                        ? 'Cartesia API key'
                        : 'ElevenLabs API key',
                    hintText: 'Paste API key',
                    prefixIcon: const Icon(Icons.key_rounded),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  selectedProvider == 'cartesia'
                      ? 'Cartesia Sonic 3.6 supports Bengali and expressive emotion/speed controls. Generation uses your Cartesia account credits.'
                      : 'ElevenLabs v4 supports expressive delivery. Generation uses your ElevenLabs account credits.',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: AuraTheme.muted,
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your key is stored encrypted on this Windows account and is passed only to the bundled local backend. It is never uploaded to GitHub.',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: AuraTheme.muted,
                        height: 1.4,
                      ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Text(
                  'Use the standard Edge neural voice without a premium API key.',
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: AuraTheme.muted,
                      ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final key = controller.text.trim();
                if (selectedProvider != 'edge' && key.isEmpty) return;
                Navigator.of(dialogContext).pop({
                  'provider': selectedProvider,
                  'key': key,
                });
              },
              child: const Text('Save and connect'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();

    if (!mounted || result == null) return;
    try {
      final provider = result['provider'] ?? 'edge';
      final key = result['key'] ?? '';
      if (provider == 'edge') {
        await _secureStorage.delete(key: _elevenLabsKeyName);
        await _secureStorage.delete(key: _cartesiaKeyName);
      } else if (provider == 'elevenlabs') {
        await _secureStorage.write(key: _elevenLabsKeyName, value: key);
      } else if (provider == 'cartesia') {
        await _secureStorage.write(key: _cartesiaKeyName, value: key);
      }
      await _secureStorage.write(key: _providerKeyName, value: provider);
      await LocalAiServer.instance.stop();
      await _connect();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not save the voice engine settings securely: $error');
      }
    }
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.ready, required this.checking});

  final bool ready;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final color = ready ? AuraTheme.mint : const Color(0xFFFFC27A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (checking)
            const SizedBox(
              height: 12,
              width: 12,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else
            Icon(
              ready ? Icons.check_circle_rounded : Icons.cloud_off_rounded,
              size: 14,
              color: color,
            ),
          const SizedBox(width: 6),
          Text(
            checking ? 'CHECKING' : ready ? 'READY' : 'OFFLINE',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _StudioCard extends StatelessWidget {
  const _StudioCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AuraTheme.panel,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.065)),
        ),
        child: child,
      );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Text(
        value,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AuraTheme.muted,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
      );
}

class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueText,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String valueText;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                valueText,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AuraTheme.mint,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: onChanged,
          ),
        ],
      );
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? const Color(0xFFFF9A9A) : AuraTheme.mint;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                    height: 1.45,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
