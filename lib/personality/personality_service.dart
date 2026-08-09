import 'dart:convert';

import 'package:http/http.dart' as http;

class PersonalityAgent {
  const PersonalityAgent({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;

  String get displayName => name.isEmpty ? 'Unnamed agent' : name;

  factory PersonalityAgent.fromJson(Map<String, dynamic> json) {
    return PersonalityAgent(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
    );
  }
}

class PersonalityCoreService {
  const PersonalityCoreService({this.client});

  static const productionBaseUrl = 'https://api.solian.app/personality';

  final http.Client? client;

  Future<List<PersonalityAgent>> listAgents({
    required String accessToken,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.get(
        Uri.parse('${_root(baseUrl)}/agents'),
        headers: _headers(accessToken),
      );
      final body = _decode(response.body, 'agent-list');
      _checkResponse(response.statusCode, body);
      if (body is! List) {
        throw const PersonalityCoreException('Invalid agent-list response.');
      }
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            PersonalityAgent.fromJson(item)
          else if (item is Map)
            PersonalityAgent.fromJson(Map<String, dynamic>.from(item)),
      ].where((agent) => agent.id.isNotEmpty).toList();
    } finally {
      if (client == null) requestClient.close();
    }
  }

  Future<String> chat({
    required String accessToken,
    required String agentId,
    required String prompt,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.post(
        Uri.parse('${_root(baseUrl)}/v1/chat/completions'),
        headers: {..._headers(accessToken), 'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': agentId,
          'stream': false,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
        }),
      );
      final body = _decode(response.body, 'chat');
      _checkResponse(response.statusCode, body);
      if (body is! Map) {
        throw const PersonalityCoreException('Invalid chat response.');
      }
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const PersonalityCoreException('Chat response has no choices.');
      }
      final message = (choices.first as Map)['message'];
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const PersonalityCoreException('Chat response has no content.');
      }
      return content.trim();
    } finally {
      if (client == null) requestClient.close();
    }
  }

  Map<String, String> _headers(String accessToken) {
    return {'Authorization': 'Bearer ${accessToken.trim()}'};
  }

  String _root(String baseUrl) {
    return baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  }

  Object? _decode(String responseBody, String operation) {
    try {
      return jsonDecode(responseBody);
    } catch (_) {
      throw PersonalityCoreException('Invalid $operation response.');
    }
  }

  void _checkResponse(int statusCode, Object? body) {
    if (statusCode >= 200 && statusCode < 300) return;
    throw PersonalityCoreException(_errorMessage(body, statusCode));
  }

  String _errorMessage(Object? body, int statusCode) {
    if (body is Map) {
      final message = body['detail'] ?? body['message'];
      if (message != null && message.toString().isNotEmpty) {
        return message.toString();
      }
      if (body['error'] case final Map error) {
        final message = error['message'];
        if (message != null && message.toString().isNotEmpty) {
          return message.toString();
        }
      }
    }
    return 'Personality Core request failed (HTTP $statusCode).';
  }
}

class PersonalityCoreException implements Exception {
  const PersonalityCoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PersonalityCoreConfig {
  const PersonalityCoreConfig({required this.agentId});

  factory PersonalityCoreConfig.fromEnvironment() {
    return const PersonalityCoreConfig(
      agentId: String.fromEnvironment(
        'PERSONALITY_CORE_AGENT',
        defaultValue: 'michan',
      ),
    );
  }

  final String agentId;
}
