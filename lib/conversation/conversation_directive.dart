import 'dart:convert';

/// A tool call extracted from an assistant response.
class ConversationToolCall {
  const ConversationToolCall(this.name, this.args);
  final String name;
  final Map<String, dynamic> args;
}

/// A parsed assistant response: a natural-language reply plus optional tool
/// calls expressed via the JSON-directive convention (provider-agnostic).
class ConversationDirective {
  const ConversationDirective(this.reply, this.toolCalls);

  final String reply;
  final List<ConversationToolCall> toolCalls;

  /// Accepts the structured JSON-directive contract while keeping plain-text
  /// responses usable when an agent answers normally.
  factory ConversationDirective.fromAssistantText(String text) {
    final payload = _decodePayload(text);
    if (payload == null) {
      return ConversationDirective(text.trim(), const []);
    }

    final reply = payload['reply']?.toString().trim();
    final rawTools = payload['tools'];
    final toolCalls = <ConversationToolCall>[];
    if (rawTools is List) {
      for (final item in rawTools) {
        if (item is! Map) continue;
        final name = item['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final args = item['args'];
        final mapArgs = args is Map
            ? Map<String, dynamic>.from(args)
            : <String, dynamic>{};
        toolCalls.add(ConversationToolCall(name, mapArgs));
      }
    }

    return ConversationDirective(
      reply == null || reply.isEmpty ? text.trim() : reply,
      toolCalls,
    );
  }

  /// Robustly extracts the first decodable JSON object from a response,
  /// tolerating raw text, fenced ```json blocks, and embedded JSON.
  static Map<String, dynamic>? _decodePayload(String text) {
    final candidates = <String>[
      text.trim(),
      for (final match in RegExp(
        r'```(?:json)?\s*([\s\S]*?)```',
        caseSensitive: false,
      ).allMatches(text))
        match.group(1)!.trim(),
    ];
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      candidates.add(text.substring(start, end + 1));
    }

    for (final candidate in candidates) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // Fall back to the next candidate.
      }
    }
    return null;
  }
}
