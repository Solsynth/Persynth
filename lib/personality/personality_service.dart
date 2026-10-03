import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  ///
  /// [onProgress] reports the bytes handed to the socket and the length of the
  /// body, which is what a reader watching an attachment go up needs; it is
  /// called as the body is consumed, so a slow link shows up as a slow count.
  /// Completing [abortTrigger] stops the upload where it stands — the call
  /// fails like any aborted request — which is how a caller takes back an
  /// attachment the reader has already decided against.
  Future<String> uploadAttachment({
    required String filePath,
    String driveBaseUrl = productionDriveBaseUrl,
    String? contentType,
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final file = await http.MultipartFile.fromPath(
      'file',
      filePath,
      contentType: contentType == null ? null : MediaType.parse(contentType),
    );
    return _uploadDirect(
      file,
      driveBaseUrl,
      onProgress: onProgress,
      abortTrigger: abortTrigger,
    );
  }

  Future<String> _uploadDirect(
    http.MultipartFile file,
    String driveBaseUrl, {
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final uploadClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final request =
          _ProgressMultipartRequest(
              'POST',
              Uri.parse('${_root(driveBaseUrl)}/files/upload/direct'),
              onProgress: onProgress,
              abortTrigger: abortTrigger,
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

  /// Lists the account's own drive files, newest first: what the composer's
  /// cloud-file picker offers. [query] narrows by name, which is how a file
  /// uploaded months ago is found without paging back to it.
  ///
  /// The listing is every file the account owns, folders and every media type
  /// included; the caller decides which of them a turn can carry.
  Future<List<PersonalityDriveFile>> listDriveFiles({
    String driveBaseUrl = productionDriveBaseUrl,
    String? query,
    int offset = 0,
    int take = 40,
  }) async {
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    final trimmedQuery = query?.trim() ?? '';
    try {
      final uri = Uri.parse('${_root(driveBaseUrl)}/files/me').replace(
        queryParameters: {
          'offset': '$offset',
          'take': '$take',
          'order_desc': 'true',
          if (trimmedQuery.isNotEmpty) 'query': trimmedQuery,
        },
      );
      final response = await requestClient.get(
        uri,
        headers: _headers(await _requireToken()),
      );
      final body = _decode(response.body, 'file-list');
      _checkResponse(response.statusCode, body);
      if (body is! List) {
        throw const PersonalityCoreException('Invalid file-list response.');
      }
      return [for (final entry in body) ?PersonalityDriveFile.fromJson(entry)];
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

  /// One drive file by id, for a link the listing did not show: the reader
  /// pastes an id, and the name and type come back from the drive rather than
  /// from what they typed.
  Future<PersonalityDriveFile> driveFile(
    String fileId, {
    String driveBaseUrl = productionDriveBaseUrl,
  }) async {
    final id = fileId.trim();
    if (id.isEmpty) {
      throw const PersonalityCoreException('A file id is required.');
    }
    final requestClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final response = await requestClient.get(
        Uri.parse(
          '${_root(driveBaseUrl)}/files/${Uri.encodeComponent(id)}/info',
        ),
        headers: _headers(await _requireToken()),
      );
      final body = _decode(response.body, 'file-info');
      _checkResponse(response.statusCode, body);
      final file = PersonalityDriveFile.fromJson(body);
      if (file == null) {
        throw const PersonalityCoreException('Invalid file-info response.');
      }
      return file;
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

  /// The URL a drive file is served from — what a preview fetches. The
  /// endpoint is behind the account, so whoever fetches it supplies the bearer
  /// token; this only names it.
  static String driveFileUrl(String driveBaseUrl, String fileId) {
    final base = driveBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$base/files/${Uri.encodeComponent(fileId)}';
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

/// One file in the account's Solar Network drive, as the composer's link
/// picker needs it: enough to draw a tile and to reference the file in a turn.
@immutable
class PersonalityDriveFile {
  const PersonalityDriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    this.byteSize,
  });

  /// The drive id a run references the file by.
  final String id;

  /// The name it was uploaded under, empty when the drive has none.
  final String name;

  /// The file's media type, as the drive stored it.
  final String mimeType;

  /// How many bytes it is, when the drive said.
  final int? byteSize;

  /// Whether a turn can carry it: the run protocol hands drive files to the
  /// model as images, so an image is the only kind worth offering.
  bool get isImage => mimeType.startsWith('image/');

  /// What the tile and its tooltip call it.
  String get displayName => name.trim().isEmpty ? id : name.trim();

  /// One file out of a drive listing, or null when the entry says nothing a
  /// reader could act on — no id.
  static PersonalityDriveFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final object = json['object'];
    final size = object is Map ? object['size'] : null;
    return PersonalityDriveFile(
      id: id,
      name: json['name']?.toString() ?? '',
      mimeType: json['mime_type']?.toString() ?? '',
      byteSize: size is num ? size.toInt() : null,
    );
  }
}

class PersonalityCoreException implements Exception {
  const PersonalityCoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A multipart upload that counts the body as it goes and that the caller can
/// abort.
///
/// `package:http` only honours [Abortable.abortTrigger] on requests that
/// declare it, and [http.MultipartRequest] does not — a picked attachment has
/// to be cancellable the moment the reader takes it back out of the queue, so
/// this carries the trigger itself. Counting here, where the body is read,
/// reports what has actually left the app for the socket rather than what the
/// file weighs.
class _ProgressMultipartRequest extends http.MultipartRequest
    with http.Abortable {
  _ProgressMultipartRequest(
    super.method,
    super.url, {
    this.onProgress,
    this.abortTrigger,
  });

  /// Called with the bytes read so far and the body's full length.
  final void Function(int sent, int total)? onProgress;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    final body = super.finalize();
    final report = onProgress;
    if (report == null) return body;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      body.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            sink.add(chunk);
            report(sent, total);
          },
        ),
      ),
    );
  }
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
