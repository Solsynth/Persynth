import 'package:flutter/foundation.dart';
import 'package:super_context_menu/super_context_menu.dart';

/// What a conversation row's context menu reports back.
enum ConversationRowAction { moveToGroup, removeFromGroup, delete }

/// What a group tile's context menu reports back.
enum ConversationGroupAction { rename, archive, unarchive, delete }

/// A conversation's own menu: file it into a group, take it back out, or
/// delete it. The list opens it on a secondary click, so these are the same
/// actions the selection strip offers for a whole batch.
Menu conversationRowMenu({
  required bool grouped,
  required ValueChanged<ConversationRowAction> onSelected,
}) {
  return Menu(
    children: [
      MenuAction(
        title: 'Move to group…',
        callback: () => onSelected(ConversationRowAction.moveToGroup),
      ),
      if (grouped)
        MenuAction(
          title: 'Remove from group',
          callback: () => onSelected(ConversationRowAction.removeFromGroup),
        ),
      MenuSeparator(),
      MenuAction(
        title: 'Delete',
        attributes: const MenuActionAttributes(destructive: true),
        callback: () => onSelected(ConversationRowAction.delete),
      ),
    ],
  );
}

/// A group tile's menu. Archiving is the reversible half of deleting, so the
/// item swaps to Unarchive once the group is filed away: the group leaves the
/// list either way, but only deleting releases the retention it carried.
Menu conversationGroupMenu({
  required bool archived,
  required ValueChanged<ConversationGroupAction> onSelected,
}) {
  return Menu(
    children: [
      MenuAction(
        title: 'Rename',
        callback: () => onSelected(ConversationGroupAction.rename),
      ),
      MenuAction(
        title: archived ? 'Unarchive' : 'Archive',
        callback: () => onSelected(
          archived
              ? ConversationGroupAction.unarchive
              : ConversationGroupAction.archive,
        ),
      ),
      MenuSeparator(),
      MenuAction(
        title: 'Delete',
        attributes: const MenuActionAttributes(destructive: true),
        callback: () => onSelected(ConversationGroupAction.delete),
      ),
    ],
  );
}
