import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  const ApiClient();

  static const String _baseUrl = String.fromEnvironment(
    'AURA_API_BASE_URL',
    defaultValue: 'https://aura-voice-api.onrender.com',
  );

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _accessKey = 'aura_access_token';
  static const String _refreshKey = 'aura_refresh_token';

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Future<Map<String, String>> _headers({
    String accept = 'application/json',
    bool includeJson = false,
    bool mobile = true,
  }) async {
    final token = await _secureStorage.read(key: _accessKey);
    return {
      'Accept': accept,
      if (includeJson) 'Content-Type': 'application/json',
      if (mobile) 'X-Client-Type': 'mobile',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<void> _storeSessionHeaders(http.Response response) async {
    final access = response.headers['x-aura-access-token'];
    final refresh = response.headers['x-aura-refresh-token'];
    if (access != null && access.isNotEmpty) {
      await _secureStorage.write(key: _accessKey, value: access);
    }
    if (refresh != null && refresh.isNotEmpty) {
      await _secureStorage.write(key: _refreshKey, value: refresh);
    }
  }

  Future<bool> _refreshSession() async {
    final refresh = await _secureStorage.read(key: _refreshKey);
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final response = await http
          .post(
            _uri('/api/v1/auth/refresh'),
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'X-Client-Type': 'mobile',
            },
            body: jsonEncode({'refresh_token': refresh}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await _clearStoredSession();
        return false;
      }
      await _storeSessionHeaders(response);
      return (await _secureStorage.read(key: _accessKey))?.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearStoredSession() async {
    await _secureStorage.delete(key: _accessKey);
    await _secureStorage.delete(key: _refreshKey);
  }

  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) send, {
    bool retryOnUnauthorized = true,
  }) async {
    final first = await send(await _headers());
    if (first.statusCode == 401 &&
        retryOnUnauthorized &&
        await _refreshSession()) {
      return send(await _headers());
    }
    return first;
  }

  Future<ApiHealthStatus> getHealthStatus() async {
    try {
      final response = await http
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        return const ApiHealthStatus.offline();
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return ApiHealthStatus(
        online: decoded['ok'] == true,
        speechConfigured: decoded['speech_ready'] == true,
        authReady: decoded['auth_ready'] == true,
        provider: decoded['speech_provider']?.toString() ?? 'none',
        version: decoded['version']?.toString() ?? '',
      );
    } catch (_) {
      return const ApiHealthStatus.offline();
    }
  }

  Future<bool> isApiHealthy() async => (await getHealthStatus()).online;

  Future<Map<String, dynamic>?> currentUser() async {
    try {
      final response = await _send(
        (headers) => http.get(_uri('/api/v1/auth/me'), headers: headers),
      );
      if (response.statusCode == 401) return null;
      if (response.statusCode != 200) {
        throw Exception(_responseMessage(response, 'Could not verify your account.'));
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (error) {
      if (error.toString().contains('401')) return null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await http
        .post(
          _uri('/api/v1/auth/login'),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Client-Type': 'mobile',
          },
          body: jsonEncode({'email': email.trim(), 'password': password}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception(_responseMessage(response, 'Sign in failed.'));
    }
    await _storeSessionHeaders(response);
    final user = jsonDecode(response.body) as Map<String, dynamic>;
    if ((await _secureStorage.read(key: _accessKey))?.isNotEmpty != true) {
      await _clearStoredSession();
      throw Exception('The server did not return a secure mobile session. Please try again.');
    }
    return user;
  }

  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final response = await http
        .post(
          _uri('/api/v1/auth/register'),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Client-Type': 'mobile',
          },
          body: jsonEncode({
            'display_name': name.trim(),
            'email': email.trim(),
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 201) {
      throw Exception(_responseMessage(response, 'Account creation failed.'));
    }
    await _storeSessionHeaders(response);
    final user = jsonDecode(response.body) as Map<String, dynamic>;
    if ((await _secureStorage.read(key: _accessKey))?.isNotEmpty != true) {
      await _clearStoredSession();
      throw Exception('The server did not return a secure mobile session. Please try again.');
    }
    return user;
  }

  Future<void> logout({bool allSessions = false}) async {
    try {
      await _send(
        (headers) => http.post(
          _uri(allSessions
              ? '/api/v1/auth/logout-all'
              : '/api/v1/auth/logout'),
          headers: headers,
        ),
        retryOnUnauthorized: false,
      );
    } finally {
      await _clearStoredSession();
    }
  }

  Future<Map<String, dynamic>> getUsage() async {
    final response = await _send(
      (headers) => http.get(_uri('/api/v1/auth/usage'), headers: headers),
    );
    if (response.statusCode != 200) {
      throw Exception(_responseMessage(response, 'Could not load usage.'));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listVoices({
    required String language,
  }) async {
    final uri = _uri('/api/v1/speech/voices').replace(
      queryParameters: {'language': language, 'limit': '100'},
    );
    final response = await _send(
      (headers) => http.get(uri, headers: headers),
    );
    if (response.statusCode != 200) {
      throw Exception(_responseMessage(response, 'Could not load Cartesia voices.'));
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final rawVoices = decoded['voices'] as List<dynamic>? ?? const [];
    return rawVoices
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
  }

  Future<Uint8List> generateSpeech({
    required String text,
    required String language,
    required double speed,
    required double volume,
    required String audioFormat,
    String? emotion,
    String? voiceId,
  }) async {
    final response = await _send(
      (headers) => http.post(
        _uri('/api/v1/speech/generate'),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
          'Accept': audioFormat == 'mp3' ? 'audio/mpeg' : 'audio/wav',
        },
        body: jsonEncode({
          'text': text,
          'language': language,
          'audio_format': audioFormat,
          'speed': speed,
          'volume': volume,
          if (emotion != null && emotion.isNotEmpty) 'emotion': emotion,
          if (voiceId != null && voiceId.isNotEmpty)
            'voice_profile_id': voiceId,
        }),
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(_responseMessage(response, 'Speech generation failed.'));
    }
    if (response.bodyBytes.isEmpty) {
      throw Exception('The speech engine returned an empty audio file.');
    }
    return response.bodyBytes;
  }

  String _responseMessage(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      if (detail is Map<String, dynamic>) {
        return detail['message']?.toString() ??
            detail['code']?.toString() ??
            fallback;
      }
      if (detail is String && detail.isNotEmpty) return detail;
    } catch (_) {
      // Keep the user-facing message generic when the response isn't JSON.
    }
    return '$fallback (HTTP ${response.statusCode})';
  }
}

class ApiHealthStatus {
  const ApiHealthStatus({
    required this.online,
    required this.speechConfigured,
    required this.authReady,
    required this.provider,
    required this.version,
  });

  const ApiHealthStatus.offline()
      : online = false,
        speechConfigured = false,
        authReady = false,
        provider = 'none',
        version = '';

  final bool online;
  final bool speechConfigured;
  final bool authReady;
  final String provider;
  final String version;
}
