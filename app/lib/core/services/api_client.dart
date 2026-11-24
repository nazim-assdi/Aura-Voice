import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  const ApiClient();

  static const String defaultBaseUrl = String.fromEnvironment(
    'AURA_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const String _baseUrlKey = 'aura_api_base_url';

  Future<String> loadBaseUrl() async {
    return (await SharedPreferencesAsync().getString(_baseUrlKey)) ??
        defaultBaseUrl;
  }

  Future<void> saveBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value);
    await SharedPreferencesAsync().setString(_baseUrlKey, normalized);
  }

  Future<Map<String, dynamic>> health({String? baseUrl}) async {
    final url = await _resolveBaseUrl(baseUrl);
    final response = await http
        .get(_uri(url, '/health'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ApiClientException(
        'Backend returned HTTP ${response.statusCode}.',
      );
    }
    return _decodeJson(response.body);
  }

  Future<bool> isApiHealthy({String? baseUrl}) async {
    try {
      final response = await health(baseUrl: baseUrl);
      return response['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<SpeechVoice>> fetchVoices({
    String? baseUrl,
    required String locale,
  }) async {
    final url = await _resolveBaseUrl(baseUrl);
    final response = await http
        .get(
          _uri(
            url,
            '/api/v1/speech/voices',
            queryParameters: {'locale': locale},
          ),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw _responseException(response);
    }
    final decoded = _decode(response.body);
    if (decoded is! List<dynamic>) {
      throw const ApiClientException('The voice list response is invalid.');
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(SpeechVoice.fromJson)
        .toList(growable: false);
  }

  Future<Uint8List> generateSpeech({
    String? baseUrl,
    required String text,
    required String voice,
    required String language,
    int rate = 0,
    int pitch = 0,
    String delivery = 'natural',
  }) async {
    final url = await _resolveBaseUrl(baseUrl);
    final response = await http
        .post(
          _uri(url, '/api/v1/speech/generate'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'language': language,
            'voice': voice,
            'rate': rate,
            'pitch': pitch,
            'delivery': delivery,
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode != 200) {
      throw _responseException(response);
    }
    if (response.bodyBytes.isEmpty) {
      throw const ApiClientException(
        'The speech service returned an empty audio file.',
      );
    }
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('audio/')) {
      throw const ApiClientException(
        'The speech service did not return an audio file.',
      );
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  Future<String> _resolveBaseUrl(String? value) async =>
      _normalizeBaseUrl(value ?? await loadBaseUrl());

  String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const ApiClientException(
        'Enter a valid backend URL beginning with http:// or https://.',
      );
    }
    return normalized;
  }

  Uri _uri(
    String baseUrl,
    String path, {
    Map<String, String>? queryParameters,
  }) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: queryParameters);

  Map<String, dynamic> _decodeJson(String source) {
    final decoded = _decode(source);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ApiClientException('The backend returned an invalid response.');
  }

  dynamic _decode(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      throw const ApiClientException('The backend response was not valid JSON.');
    }
  }

  ApiClientException _responseException(http.Response response) {
    try {
      final decoded = _decodeJson(response.body);
      final detail = decoded['detail'];
      if (detail is Map<String, dynamic>) {
        final message = detail['message'];
        if (message is String && message.trim().isNotEmpty) {
          return ApiClientException(message);
        }
      }
      if (detail is String && detail.trim().isNotEmpty) {
        return ApiClientException(detail);
      }
    } catch (_) {
      // Fall through to a status-only error.
    }
    return ApiClientException(
      'Speech service request failed (HTTP ${response.statusCode}).',
    );
  }
}

class SpeechVoice {
  const SpeechVoice({
    required this.id,
    required this.name,
    required this.locale,
    required this.gender,
  });

  final String id;
  final String name;
  final String locale;
  final String gender;

  factory SpeechVoice.fromJson(Map<String, dynamic> json) => SpeechVoice(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? json['id'] as String? ?? 'Voice',
        locale: json['locale'] as String? ?? '',
        gender: json['gender'] as String? ?? '',
      );

  String get label => '$name · $gender';
}

class ApiClientException implements Exception {
  const ApiClientException(this.message);

  final String message;

  @override
  String toString() => message;
}
