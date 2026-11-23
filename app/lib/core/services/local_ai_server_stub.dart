class LocalAiServer {
  const LocalAiServer._();

  static const instance = LocalAiServer._();

  Future<bool> ensureRunning({required String baseUrl}) async => false;

  Future<void> stop() async {}
}
