import 'dart:async';
import 'dart:io';

import 'api_client.dart';

class LocalAiServer {
  LocalAiServer._();

  static final instance = LocalAiServer._();

  Process? _process;

  Future<bool> ensureRunning({required String baseUrl}) async {
    if (!Platform.isWindows) return false;

    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.scheme != 'http' ||
        (uri.host != '127.0.0.1' && uri.host != 'localhost') ||
        uri.port != 8000) {
      return false;
    }

    const api = ApiClient();
    if (await api.isApiHealthy(baseUrl: baseUrl)) return true;

    if (_process == null) {
      final appDirectory = File(Platform.resolvedExecutable).parent;
      final server = File(
        '${appDirectory.path}${Platform.pathSeparator}aura-ai-server.exe',
      );
      if (!await server.exists()) return false;

      try {
        final process = await Process.start(
          server.path,
          const [],
          workingDirectory: appDirectory.path,
          runInShell: false,
        );
        _process = process;
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        unawaited(
          process.exitCode.then((_) {
            if (identical(_process, process)) _process = null;
          }),
        );
      } on ProcessException {
        return false;
      }
    }

    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (await api.isApiHealthy(baseUrl: baseUrl)) return true;
      if (_process == null) return false;
    }
    return false;
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
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
