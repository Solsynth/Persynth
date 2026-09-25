/// Shared plumbing for plugins whose tools call Solar Network.
///
/// Two jobs, both about what the model ends up reading: run a call without
/// letting a transport failure become an exception the run has to absorb, and
/// hand back compact JSON, so a result costs the model the fields it needs
/// rather than the whole wire object.
///
/// A Solar Network client is typed and its models are complete — a post
/// carries its author, its own replies, its collections and its fediverse
/// shadow. Serializing one whole would spend an entire context window on a
/// single item, so every plugin here projects to a few named fields. That
/// projection is the plugin's actual work; the call is one line.
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// Runs one Solar Network call and returns what the model should read.
///
/// The answer is JSON either way: the payload on success, or an object with an
/// `error`. A failure — not signed in, nothing there, refused, offline — is a
/// fact about the request rather than a defect of the tool, so it is reported
/// as an answer. The model can then correct itself, which is the whole
/// difference between a dead end and a second attempt.
Future<String> solarToolResult(Future<Object?> Function() call) async {
  try {
    return jsonEncode(await call());
  } on DioException catch (error) {
    return jsonEncode({'error': solarFailureText(error)});
  } catch (error) {
    return jsonEncode({'error': 'The request failed: $error'});
  }
}

/// A timestamp as the model should read it: UTC to the second, with the `Z`.
///
/// The wire format carries sub-second precision the model never needs, and a
/// bare local-time string would be ambiguous the moment the user travels.
String? solarStamp(DateTime? time) {
  if (time == null) return null;
  final utc = time.toUtc().toIso8601String();
  final dot = utc.indexOf('.');
  return dot < 0 ? utc : '${utc.substring(0, dot)}Z';
}

/// A `take` argument clamped to what one call may ask for.
///
/// Models routinely pass a number as a string, or ask for more than fits in a
/// context window; neither should end the call.
int solarTake(
  Map<String, dynamic> arguments, {
  int fallback = 10,
  int max = 30,
}) {
  final raw = arguments['take'];
  final asked = raw is int ? raw : int.tryParse('${raw ?? ''}');
  return asked == null ? fallback : asked.clamp(1, max);
}

/// A required string argument, or null when the model left it out or blank.
String? solarText(Map<String, dynamic> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

/// What to tell the model about a failed Solar Network call.
///
/// Says what the status means for the user, not just what it was: `401` is a
/// session that needs signing in again, and telling the model `HTTP 401` alone
/// invites it to retry a request that cannot succeed.
String solarFailureText(DioException error) {
  final said = _serverSaid(error.response?.data);
  final suffix = said.isEmpty ? '' : ': $said';
  final status = error.response?.statusCode;
  if (status == null) {
    return 'Could not reach Solar Network (${error.type.name})$suffix.';
  }
  final reason = switch (status) {
    400 => 'Solar Network rejected the request',
    401 => 'the user is not signed in to Solar Network, or the session expired',
    403 => 'the account is not allowed to do that',
    404 => 'there is no such item',
    409 => 'that conflicts with an existing item',
    429 => 'too many requests right now',
    >= 500 => 'Solar Network hit an internal error',
    _ => 'Solar Network refused the request',
  };
  return '$reason (HTTP $status)$suffix.';
}

/// The message a Solar Network error body carries, if any.
///
/// The gateway answers a failure with `{"message": ...}`; some services wrap a
/// lower layer's error instead, which may be prose rather than an object.
String _serverSaid(Object? data) {
  if (data is Map) {
    for (final key in const ['message', 'error', 'detail']) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  }
  if (data is String && data.trim().isNotEmpty && data.length <= 200) {
    return data.trim();
  }
  return '';
}

/// Trims [text] to [limit] characters, marking that it was cut.
///
/// A post body can be arbitrarily long; the model needs enough of it to act,
/// and needs to know when there was more.
String? solarClip(String? text, {int limit = 600}) {
  if (text == null) return null;
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}… [truncated]';
}
