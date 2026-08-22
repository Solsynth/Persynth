import 'package:synth_pet/conversation/conversation_message.dart';

/// Prunes the oldest messages once a conversation exceeds [maxMessages],
/// always preserving the leading system prompt so persona/instructions hold.
class CompactionPolicy {
  const CompactionPolicy(this.maxMessages);

  final int maxMessages;

  List<ConversationMessage> apply(List<ConversationMessage> messages) {
    if (messages.length <= maxMessages) return List.of(messages);

    final system = messages
        .where((m) => m.role == ConversationRole.system)
        .toList();
    final rest = messages
        .where((m) => m.role != ConversationRole.system)
        .toList();
    final keptCount = maxMessages - system.length;
    final kept = rest.skip(rest.length - keptCount);

    return [...system, ...kept];
  }
}
