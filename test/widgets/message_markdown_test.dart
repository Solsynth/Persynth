import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/message_markdown.dart';
import 'package:solar_network_foundation/solar_network_foundation.dart';

/// A body is drawn a paragraph at a time, so a blank line inside one reply is
/// a gap between two renders. The package's own spacing is the yardstick: a
/// blank line has to cost the same whether the body reached
/// [SolarMarkdownContent] whole or was split at that line.
Future<double> _gap(
  WidgetTester tester,
  Widget body,
  String upper,
  String lower,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPersynthTheme(Brightness.light),
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: body),
      ),
    ),
  );
  final a = tester.getRect(find.text(upper, findRichText: true));
  final b = tester.getRect(find.text(lower, findRichText: true));
  return b.top - a.bottom;
}

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
      const SolarMarkdownContent(content: body),
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

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPersynthTheme(Brightness.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MessageMarkdown(text: body),
          ),
        ),
      ),
    );

    // The sticker image sits in its own row between the two paragraphs; both
    // boundaries have to be paid, so the texts are never flush with it.
    final above = tester.getRect(find.text('Above.', findRichText: true));
    final sticker = tester.getRect(find.byType(Image));
    final below = tester.getRect(find.text('Below.', findRichText: true));

    expect(sticker.top - above.bottom, greaterThan(0));
    expect(below.top - sticker.bottom, greaterThan(0));
  });
}
