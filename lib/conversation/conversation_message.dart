/// Role of a message in a conversation turn.
enum ConversationRole { system, user, assistant, tool }

/// A single conversation message in harness memory.
class ConversationMessage {
  const ConversationMessage(
    this.role,
    this.content, {
    this.attachmentIds = const [],
  });

  final ConversationRole role;
  final String content;

  /// Solar Network drive file ids attached to this message.
  final List<String> attachmentIds;
}
