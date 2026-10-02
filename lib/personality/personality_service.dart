import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'package:persynth/auth/solar_auth_service.dart';

typedef PersonalityTokenResolver = Future<String?> Function();

class PersonalityCoreService {
  const PersonalityCoreService({this.client, this.tokenResolver});

  /// Resolves the caller's access token. Defaults to the global Solar identity
  /// provider so callers never thread tokens through individual calls.
  final PersonalityTokenResolver? tokenResolver;

  final http.Client? client;

  Future<String> _requireToken() async {
    final resolve = tokenResolver ?? SolarAuthService().accessToken;
    final token = await resolve();
    if (token == null || token.trim().isEmpty) {
      throw const PersonalityCoreException('Sign in to start a conversation.');
    }
    return token.trim();
  }

  static const productionBaseUrl = 'https://api.solian.app/personality';

  static const productionDriveBaseUrl = 'https://api.solian.app/drive';

  /// Uploads a local file to Solar Network drive and returns its id for use
  /// as a run attachment.
  ///
  /// Only files the model must read as files go here — an image. Text a caller
  /// wants the model to read as a document travels in the run itself, as a
  /// text input part, and never reaches the drive.
  Future<String> uploadAttachment({
    required String filePath,
    String driveBaseUrl = productionDriveBaseUrl,
    String? contentType,
  }) async {
    final file = await http.MultipartFile.fromPath(
      'file',
      filePath,
      contentType: contentType == null ? null : MediaType.parse(contentType),
    );
    return _uploadDirect(file, driveBaseUrl);
  }

  Future<String> _uploadDirect(
    http.MultipartFile file,
    String driveBaseUrl,
  ) async {
    final uploadClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${_root(driveBaseUrl)}/files/upload/direct'),
            )
            ..headers.addAll(_headers(await _requireToken()))
            ..files.add(file);
      final response = await uploadClient.send(request);
      final body = _decode(
        await response.stream.bytesToString(),
        'file-upload',
      );
      _checkResponse(response.statusCode, body);
      if (body is! Map || body['id'] is! String) {
        throw const PersonalityCoreException('Invalid file-upload response.');
      }
      return (body['id'] as String).trim();
    } finally {
      if (ownsClient) uploadClient.close();
    }
  }

  /// Calls the OpenAI-compatible endpoint for one short pet reply.
  Future<String> chat({
    required String agentId,
    required String prompt,
    String baseUrl = productionBaseUrl,
  }) async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.post(
        Uri.parse('${_root(baseUrl)}/v1/chat/completions'),
        headers: {
          ..._headers(await _requireToken()),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': agentId,
          'stream': false,
          'server_tools': true,
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
