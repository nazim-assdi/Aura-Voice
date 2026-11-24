class LocalAiServer {
  const LocalAiServer._();

  static const instance = LocalAiServer._();

  Future<bool> ensureRunning({
    required String baseUrl,
    String? elevenLabsApiKey,
  }) async =>
      false;

  Future<void> stop() async {}
}
