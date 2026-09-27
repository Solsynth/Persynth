import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:persynth/personality/insight_chat_controller.dart';
import 'package:persynth/personality/personality_api.dart';

/// Drops everything that was fetched for one account: the agent list, the
/// thread list, and the conversation on screen.
///
/// Called around a session change — a fresh sign-in, or a sign-out — so nothing
/// the next session draws was answered for the last one. The conversation is
/// dropped rather than reloaded because a re-sign-in may be a different
/// account, and the persisted threads are one request away either way.
void invalidatePersonalitySession(WidgetRef ref) {
  ref.invalidate(personalityAgentsProvider);
  ref.invalidate(personalityConversationsProvider);
  ref.invalidate(insightChatControllerProvider);
}
