import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiClient {
  const ApiClient();

  static const String _baseUrl = String.fromEnvironment(
    'AURA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  Future<bool> isApiHealthy() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> listVoices({
    required String language,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/v1/speech/voices').replace(
      queryParameters: {'language': language, 'limit': '100'},
    );
    final response = await http
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));

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
    String? voiceId,
  }) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/api/v1/speech/generate'),
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'audio/wav',
          },
          body: jsonEncode({
            'text': text,
            'language': language,
            'audio_format': 'wav',
            'speed': speed,
            if (voiceId != null && voiceId.isNotEmpty)
              'voice_profile_id': voiceId,
          }),
        )
        .timeout(const Duration(seconds: 90));

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
