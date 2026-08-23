/// Events emitted on the [ConversationController.events] broadcast stream.
sealed class ConversationEvent {
  const ConversationEvent();
}

/// The assistant turn has started; the UI should show a thinking indicator.
final class ThinkingStarted extends ConversationEvent {
  const ThinkingStarted();
}
/// A streamed token fragment of the assistant's reply.
final class ChunkReceived extends ConversationEvent {
  const ChunkReceived(this.delta);
  final String delta;
}

/// A streamed fragment of the assistant's reasoning (thinking) text.
final class ThinkingChunk extends ConversationEvent {
  const ThinkingChunk(this.delta);
  final String delta;
}

/// The assistant message for the turn is complete.
final class MessageCompleted extends ConversationEvent {
  const MessageCompleted(this.text);
  final String text;
}

/// A tool was invoked; [result] is `'running'`, the resolved value, or
/// `'unknown tool'` when no registered tool matched [name].
final class ToolInvoked extends ConversationEvent {
  const ToolInvoked(this.id, this.name, this.args, this.result);
  final String id;
  final String name;
  final Map<String, dynamic> args;
  final String result;
}

/// The controller busy state changed ([busy] == true while a turn runs).
final class StatusChanged extends ConversationEvent {
  const StatusChanged(this.busy);
  final bool busy;
}

/// A different conversation is now active (new or opened); the UI should
/// rebuild its bubbles from [ConversationController.messages].
final class ConversationOpened extends ConversationEvent {
  const ConversationOpened();
}

/// An error occurred during the turn.
final class ErrorOccurred extends ConversationEvent {
  const ErrorOccurred(this.message);
  final String message;
}
