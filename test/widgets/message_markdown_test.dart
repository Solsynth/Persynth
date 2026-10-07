import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/markdown_code_block.dart';
import 'package:persynth/widgets/message_markdown.dart';

/// Pumps [body] alone in a Persynth-themed surface, the way a reply is mounted.
Future<void> _pump(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPersynthTheme(Brightness.light),
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: body),
      ),
    ),
  );
}

/// The gap between two paragraphs of one body, in whatever renderer [body] is.
Future<double> _gap(
  WidgetTester tester,
  Widget body,
  String upper,
  String lower,
) async {
  await _pump(tester, body);
  final a = tester.getRect(find.text(upper, findRichText: true));
  final b = tester.getRect(find.text(lower, findRichText: true));
  return b.top - a.bottom;
}

/// The two paragraphs set as the renderer sets them when nothing splits them.
Widget _oneRender(String body) => Builder(
  builder: (context) =>
      MarkdownBody(data: body, styleSheet: persynthMarkdownStyleSheet(context)),
);

void main() {
  testWidgets('spaces a blank line as much as Markdown itself does', (
    tester,
  ) async {
    const body = 'First paragraph.\n\nSecond paragraph.';

    final rendered = await _gap(
      tester,
      const MessageMarkdown(text: body),
      'First paragraph.',
      'Second paragraph.',
    );
    final reference = await _gap(
      tester,
      _oneRender(body),
      'First paragraph.',
      'Second paragraph.',
    );

    expect(rendered, reference);
    expect(rendered, greaterThan(0));
  });

  testWidgets('keeps a paragraph apart from the sticker between two of them', (
    tester,
  ) async {
    const body = 'Above.\n\n:pack+wave:\n\nBelow.';

    await _pump(tester, const MessageMarkdown(text: body));

    // The sticker image sits in its own row between the two paragraphs; both
    // boundaries have to be paid, so the texts are never flush with it.
    final above = tester.getRect(find.text('Above.', findRichText: true));
    final sticker = tester.getRect(find.byType(Image));
    final below = tester.getRect(find.text('Below.', findRichText: true));

    expect(sticker.top - above.bottom, greaterThan(0));
    expect(below.top - sticker.bottom, greaterThan(0));
  });

  testWidgets('keeps a blank line inside a fence with its code', (
    tester,
  ) async {
    // A blank line in a fenced block is part of the code. Splitting the body
    // there used to leave a fence dangling on each side of the seam, and the
    // backticks came out as text.
    const body =
        "Here it is:\n\n"
        "```dart\nvoid main() {\n\n  print('hi');\n}\n```\n\n"
        'That is it.';

    await _pump(tester, const MessageMarkdown(text: body));

    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    final block = tester.widget<MarkdownCodeBlock>(
      find.byType(MarkdownCodeBlock),
    );
    expect(block.code, "void main() {\n\n  print('hi');\n}");
    expect(block.language, 'dart');
    expect(find.textContaining('```', findRichText: true), findsNothing);
    expect(find.text('Here it is:', findRichText: true), findsOneWidget);
    expect(find.text('That is it.', findRichText: true), findsOneWidget);
  });

  testWidgets('names each fence by the language it was opened with', (
    tester,
  ) async {
    const body =
        '```dart\nvar a = 1;\n```\n\n'
        '```\nplain\n```\n\n'
        '```ruby\nputs 1\n```';

    await _pump(tester, const MessageMarkdown(text: body));

    expect(find.byType(MarkdownCodeBlock), findsNWidgets(3));
    // A fence that named a language carries it; a bare one carries nothing.
    expect(find.text('dart', findRichText: true), findsOneWidget);
    expect(find.text('ruby', findRichText: true), findsOneWidget);
  });

  testWidgets('leaves an inline code span as text, not as a block', (
    tester,
  ) async {
    await _pump(
      tester,
      const MessageMarkdown(text: 'Set `count` to one and it is done.'),
    );

    expect(find.byType(MarkdownCodeBlock), findsNothing);
  });
}
