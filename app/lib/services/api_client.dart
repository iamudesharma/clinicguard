import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class TokenResponse {
  final String token;
  final String room;
  final String url;

  const TokenResponse({required this.token, required this.room, required this.url});
}

class ApiClient {
  final http.Client _client = http.Client();

  /// Requests a LiveKit access token from the Python backend.
  Future<TokenResponse> fetchToken({String? room, String? userId}) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/token');
    final res = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'user_id': userId ?? AppConfig.defaultUserId,
            if (room != null && room.isNotEmpty) 'room': room,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('token request failed (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return TokenResponse(
      token: data['token'] as String,
      room: data['room'] as String,
      url: data['url'] as String,
    );
  }

  Future<Map<String, dynamic>> fetchSummary(String roomId) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/sessions/$roomId/summary');
    final res = await _client.get(uri).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      String detail = 'summary request failed (${res.statusCode})';
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['detail'] != null) detail = body['detail'] as String;
      } catch (_) {}
      throw Exception(detail);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
