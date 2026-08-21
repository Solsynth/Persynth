/// Role of a message in a conversation turn.
enum ConversationRole { system, user, assistant, tool }

/// A single conversation message in harness memory.
class ConversationMessage {
  const ConversationMessage(this.role, this.content);

  final ConversationRole role;
  final String content;

  /// Maps to the OpenAI-compatible wire format. Tool results are sent as a
  /// `user` message with a `[tool result]` prefix to avoid relying on endpoint
  /// tool-message support. System/user/assistant map directly.
  Map<String, String> toWire() {
    final wireRole = role == ConversationRole.tool ? 'user' : role.name;
    final wireContent = role == ConversationRole.tool
        ? '[tool result] $content'
        : content;
    return {'role': wireRole, 'content': wireContent};
  }
}
