/// Role of a message in a conversation turn.
enum ConversationRole { system, user, assistant, tool }

/// A single conversation message in harness memory.
class ConversationMessage {
  const ConversationMessage(
    this.role,
    this.content, {
    this.attachmentIds = const [],
    this.reasoningContent,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
  });

  final ConversationRole role;
  final String content;

  /// Solar Network drive file ids attached to this message.
  final List<String> attachmentIds;

  /// Assistant messages: reasoning captured at generation time, if any.
  final String? reasoningContent;

  /// Assistant messages: tool calls the model requested this turn.
  final List<ConversationToolCall> toolCalls;

  /// Tool messages: the call this row answers.
  final String? toolCallId;
  final String? toolName;
}

/// A tool call recorded on an assistant message.
class ConversationToolCall {
  const ConversationToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;
}
