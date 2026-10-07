import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/code_highlighter.dart';

/// A fenced code block: the pane a reply's code is read in.
///
/// The renderer's own `pre` sets the block in whatever `monospace` the platform
/// picks — on this machine that is not IBM Plex Mono, the face the rest of the
/// app writes its machines in — at a seventh below the body, in a well one
/// barely-there step off the bubble it sits in. Nothing about that says *code*,
/// which is the one thing a reply from a companion who writes code has to say.
///
/// So the pane is drawn here instead: the app's mono face at a size that can be
/// read for a screenful, on the page's own paper (the scheme's surface, the same
/// tone the composer's field is filled with) with a control hairline around it,
/// the language a fence named set quietly on the first line's shoulder, and the
/// only colour anywhere in the bubble spent on the code's own words.
class MarkdownCodeBlock extends StatefulWidget {
  const MarkdownCodeBlock({super.key, required this.code, this.language});

  /// The block's text, without the fence and without the newline that ends it.
  final String code;

  /// The language the fence named, or null when it named none.
  final String? language;

  @override
  State<MarkdownCodeBlock> createState() => _MarkdownCodeBlockState();
}

class _MarkdownCodeBlockState extends State<MarkdownCodeBlock> {
  /// The pane scrolls sideways rather than wrapping: a wrapped line of code is
  /// two lines that a reader has to read as one.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final codeStyle = TextStyle(
      fontFamily: PersynthFonts.mono,
      fontSize: 13,
      height: 1.5,
      color: scheme.onSurface,
    );
    final language = widget.language;

    return Padding(
      // Room to breathe on all four sides, and only a step between the label
      // and the first line: the label is set on that line's own shoulder rather
      // than on a bar above it, so a three-line block stays three lines tall.
      padding: const EdgeInsets.fromLTRB(14, 11, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _pane(codeStyle, scheme)),
          if (language != null)
            Padding(
              // Nudged down onto the first line's cap, which sits inside a
              // taller line box than the label's own.
              padding: const EdgeInsets.only(left: 12, top: 3),
              child: Text(
                language,
                style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.6),
              ),
            ),
        ],
      ),
    );
  }

  /// The code itself: one span per run the highlighter proved, in a viewport
  /// that is inset from the well and stops short of the label.
  Widget _pane(TextStyle codeStyle, ColorScheme scheme) {
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: SelectableText.rich(
          TextSpan(
            style: codeStyle,
            children: [
              for (final token in tokenizeCode(widget.code, widget.language))
                switch (token.kind) {
                  // The code's own tone, and the one the highlighter leaves
                  // words it did not claim in.
                  CodeTokenKind.text => TextSpan(text: token.text),
                  CodeTokenKind.keyword => TextSpan(
                    text: token.text,
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                  // Comments recede: they are the one part of a block a reader
                  // is meant to be able to skip.
                  CodeTokenKind.comment => TextSpan(
                    text: token.text,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                },
            ],
          ),
          style: codeStyle,
        ),
      ),
    );
  }
}

/// Draws `pre` — a fenced block, or an indented one — as [MarkdownCodeBlock].
///
/// Registering this also takes the library's own `pre` out of the picture: it
/// routes the block's text through [visitText] and then through this builder,
/// and since neither hands a widget back to it, nothing of its box survives.
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    var code = element.textContent;
    // The parser leaves the block's own text ending in the newline before the
    // closing fence; a block that keeps it ends with an empty line.
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return MarkdownCodeBlock(code: code, language: _languageOf(element));
  }
}

/// The language a fence named, from the class the parser hangs off its `code`
/// child — `language-dart` for a fence opened with ```dart.
///
/// Anything that is not a plain language token is dropped: the info string of a
/// fence is free text, and a stray brace or quote has no business on the pane.
String? _languageOf(md.Element pre) {
  for (final child in pre.children ?? const <md.Node>[]) {
    if (child is! md.Element || child.tag != 'code') continue;
    for (final name in (child.attributes['class'] ?? '').split(' ')) {
      final language = name.startsWith('language-')
          ? name.substring('language-'.length)
          : name;
      if (_languageToken.hasMatch(language)) return language.toLowerCase();
    }
  }
  return null;
}

final _languageToken = RegExp(r'^[A-Za-z][\w+#.-]{0,19}$');
