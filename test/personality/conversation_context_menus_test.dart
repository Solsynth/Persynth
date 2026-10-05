import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/screens/conversation_context_menus.dart';
import 'package:super_context_menu/super_context_menu.dart';

import '../localization_harness.dart';

/// A context menu is rendered by the platform — natively on macOS and Linux —
/// so a widget test cannot click its items. These read the menu the list would
/// open and press an item directly instead. That is the one place where the
/// item a reader picks and the action the app runs are joined, so this is what
/// covers the menus themselves.

List<MenuAction> _actions(Menu menu) =>
    menu.children.whereType<MenuAction>().toList();

List<String?> _titles(Menu menu) =>
    _actions(menu).map((action) => action.title).toList();

/// Presses the item titled [title]; fails when the menu does not offer it.
void _press(Menu menu, String title) {
  _actions(menu)
      .firstWhere(
        (action) => action.title == title,
        orElse: () => fail('$title is not offered by ${_titles(menu)}'),
      )
      .callback();
}

({Menu menu, List<ConversationRowAction> picks}) _rowMenu({
  required bool grouped,
}) {
  final picks = <ConversationRowAction>[];
  return (
    menu: conversationRowMenu(grouped: grouped, onSelected: picks.add),
    picks: picks,
  );
}

({Menu menu, List<ConversationGroupAction> picks}) _groupMenu({
  required bool archived,
}) {
  final picks = <ConversationGroupAction>[];
  return (
    menu: conversationGroupMenu(archived: archived, onSelected: picks.add),
    picks: picks,
  );
}

void main() {
  setUpAll(initializeLocalization);

  testWidgets('a row menu files, unfiles and deletes', (tester) async {
    await loadLocalizedCopy(tester);
    final row = _rowMenu(grouped: false);
    expect(_titles(row.menu), ['Move to group…', 'Delete']);

    _press(row.menu, 'Move to group…');
    _press(row.menu, 'Delete');
    expect(row.picks, [
      ConversationRowAction.moveToGroup,
      ConversationRowAction.delete,
    ]);
  });

  testWidgets('only a filed row offers to leave its group', (tester) async {
    await loadLocalizedCopy(tester);
    final row = _rowMenu(grouped: true);
    expect(_titles(row.menu), [
      'Move to group…',
      'Remove from group',
      'Delete',
    ]);

    _press(row.menu, 'Remove from group');
    expect(row.picks, [ConversationRowAction.removeFromGroup]);
  });

  testWidgets('a group menu renames, files away and deletes', (tester) async {
    await loadLocalizedCopy(tester);
    final group = _groupMenu(archived: false);
    expect(_titles(group.menu), ['Rename', 'Archive', 'Delete']);

    _press(group.menu, 'Archive');
    _press(group.menu, 'Rename');
    expect(group.picks, [
      ConversationGroupAction.archive,
      ConversationGroupAction.rename,
    ]);
  });

  testWidgets('an archived group offers to come back instead', (tester) async {
    await loadLocalizedCopy(tester);
    final group = _groupMenu(archived: true);
    expect(_titles(group.menu), ['Rename', 'Unarchive', 'Delete']);

    _press(group.menu, 'Unarchive');
    _press(group.menu, 'Delete');
    expect(group.picks, [
      ConversationGroupAction.unarchive,
      ConversationGroupAction.delete,
    ]);
  });

  testWidgets('deleting is marked destructive in both menus', (
    tester,
  ) async {
    await loadLocalizedCopy(tester);
    expect(
      _actions(_rowMenu(grouped: false).menu).last.attributes.destructive,
      isTrue,
    );
    expect(
      _actions(_groupMenu(archived: false).menu).last.attributes.destructive,
      isTrue,
    );
  });
}
