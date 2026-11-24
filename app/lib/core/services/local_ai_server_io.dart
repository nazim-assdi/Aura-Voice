import 'dart:async';
import 'dart:io';

import 'api_client.dart';

class LocalAiServer {
  LocalAiServer._();

  static final instance = LocalAiServer._();

  Process? _process;
  String? _processConfigFingerprint;

  Future<bool> ensureRunning({
    required String baseUrl,
    String speechProvider = 'edge',
    String? elevenLabsApiKey,
    String? cartesiaApiKey,
  }) async {
    if (!Platform.isWindows) return false;

    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.scheme != 'http' ||
        (uri.host != '127.0.0.1' && uri.host != 'localhost') ||
        uri.port != 8000) {
      return false;
    }

    final provider = speechProvider.trim().toLowerCase();
    if (!{'edge', 'elevenlabs', 'cartesia'}.contains(provider)) {
      return false;
    }
    final elevenKey = elevenLabsApiKey?.trim() ?? '';
    final cartesiaKey = cartesiaApiKey?.trim() ?? '';
    if (provider == 'elevenlabs' && elevenKey.isEmpty) return false;
    if (provider == 'cartesia' && cartesiaKey.isEmpty) return false;

    // This fingerprint is used only in memory to restart the local backend if
    // the selected provider or its credential changes. It is never logged.
    final configFingerprint = '$provider\u0000$elevenKey\u0000$cartesiaKey';
    if (_process != null && _processConfigFingerprint != configFingerprint) {
      await stop();
    }

    const api = ApiClient();
    final expectedProvider = provider == 'edge' ? 'edge-tts' : provider;

    Future<Map<String, dynamic>?> readHealth() async {
      try {
        return await api.health(baseUrl: baseUrl);
      } catch (_) {
        return null;
      }
    }

    final existingHealth = await readHealth();
    if (existingHealth?['ok'] == true) {
      if (existingHealth?['speech_provider'] == expectedProvider) return true;
      // Do not terminate a server that this app did not start.
      if (_process == null) return false;
      await stop();
    }

    if (_process == null) {
      final appDirectory = File(Platform.resolvedExecutable).parent;
      final server = File(
        '${appDirectory.path}${Platform.pathSeparator}backend_runtime${Platform.pathSeparator}aura-ai-server.exe',
      );
      if (!await server.exists()) return false;

      final environment = Map<String, String>.from(Platform.environment);
      environment['AURA_SPEECH_PROVIDER'] = provider;
      if (elevenKey.isEmpty) {
        environment.remove('AURA_ELEVENLABS_API_KEY');
      } else {
        environment['AURA_ELEVENLABS_API_KEY'] = elevenKey;
      }
      if (cartesiaKey.isEmpty) {
        environment.remove('AURA_CARTESIA_API_KEY');
      } else {
        environment['AURA_CARTESIA_API_KEY'] = cartesiaKey;
      }

      try {
        final process = await Process.start(
          server.path,
          const [],
          workingDirectory: File(server.path).parent.path,
          environment: environment,
          runInShell: false,
        );
        _process = process;
        _processConfigFingerprint = configFingerprint;
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        unawaited(
          process.exitCode.then((_) {
            if (identical(_process, process)) {
              _process = null;
              _processConfigFingerprint = null;
            }
          }),
        );
      } on ProcessException {
        return false;
      }
    }

    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final health = await readHealth();
      if (health?['ok'] == true &&
          health?['speech_provider'] == expectedProvider) {
        return true;
      }
      if (_process == null) return false;
    }
    return false;
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    _processConfigFingerprint = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    } on ProcessException {
      // The local server may already have exited.
    }
  }
}
