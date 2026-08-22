import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Context handed to a [ConversationTool] when it executes.
class ConversationToolContext {
  ConversationToolContext(this.clearHistory, this._storageProvider);

  /// Removes every message except the leading system prompt.
  final void Function() clearHistory;

  /// Lazily creates the async-backed key/value store (used by persistent
  /// tools). Deferred so tools that don't persist anything never touch the
  /// platform, which keeps the harness usable in headless/test contexts.
  final SharedPreferencesAsync Function() _storageProvider;

  SharedPreferencesAsync get storage => _storageProvider();
}

abstract class ConversationTool {
  String get name;
  String get description;

  Future<String> execute(
    Map<String, dynamic> args,
    ConversationToolContext ctx,
  );
}

/// Registry of available [ConversationTool]s keyed by name.
class ToolRegistry {
  final Map<String, ConversationTool> _tools = {};

  void register(ConversationTool tool) => _tools[tool.name] = tool;

  ConversationTool? lookup(String name) => _tools[name];

  Iterable<ConversationTool> get all => _tools.values;
}

/// Clears the running conversation history.
class ClearConversationTool implements ConversationTool {
  @override
  String get name => 'clear';

  @override
  String get description => 'Clear the conversation history.';

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ConversationToolContext ctx,
  ) async {
    ctx.clearHistory();
    return 'Conversation cleared.';
  }
}

/// Persists a note to local storage for later recall.
class RememberTool implements ConversationTool {
  static const _key = 'conversation_notes';

  @override
  String get name => 'remember';

  @override
  String get description =>
      'Save a note to memory. Provide the note text via the "note" argument.';

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ConversationToolContext ctx,
  ) async {
    final raw = args['note'];
    final note = (raw is String ? raw : raw?.toString() ?? '').trim();
    if (note.isEmpty) return 'No note provided.';

    final existing = await ctx.storage.getString(_key);
    final notes = <dynamic>[];
    if (existing != null && existing.isNotEmpty) {
      try {
        final decoded = jsonDecode(existing);
        if (decoded is List) notes.addAll(decoded);
      } catch (_) {
        // Corrupt storage; start a fresh list.
      }
    }
    notes.add(note);
    await ctx.storage.setString(_key, jsonEncode(notes));
    return 'Saved note: $note.';
  }
}
