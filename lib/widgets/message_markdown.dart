import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/theme/app_theme.dart';
import 'package:persynth/widgets/markdown_code_block.dart';

/// Sticker placeholder convention shared with Solar Network chat:
/// `:pack-prefix+slug:`.
const stickerPattern = r':([-\w]*\+[-\w]*):';

final _stickerRegex = RegExp(stickerPattern);

final _fenceRegex = RegExp(r'^(`{3,}|~{3,})');

/// The gap between two paragraphs of one body.
///
/// [MarkdownBody] spaces the blocks inside a single render by
/// `MarkdownStyleSheet.blockSpacing`, which [persynthMarkdownStyleSheet] sets
/// to this. A blank line is a paragraph here, so the body is rendered a
/// paragraph at a time and the gap has to be paid across those renders too;
/// otherwise the model's own paragraphing reads as one wall of text. Either way
/// a blank line costs the same, which is what keeps the split invisible.
const double _kParagraphSpacing = 10;

String _stickerUrl(String placeholder) =>
    '${SolarAuthService.apiBase}/sphere/stickers/lookup/'
    '${Uri.encodeComponent(placeholder)}/open';

/// Renders one assistant message body.
///
/// The body is drawn a paragraph at a time so a paragraph that is only sticker
/// placeholders can render as stickers; everything else renders through
/// [MarkdownBody] under [persynthMarkdownStyleSheet]. A blank line here is
/// plain text, not a boundary between messages — the log's rows come from the
/// run's own events — and a blank line inside a fenced code block is neither: a
/// fence goes with its block, whole.
class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({super.key, required this.text, this.textStyle});

  final String text;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final styleSheet = persynthMarkdownStyleSheet(context);
    final body = textStyle == null
        ? styleSheet
        : styleSheet.copyWith(p: textStyle);
    final children = <Widget>[];
    for (final paragraph in _paragraphs(text)) {
      final stickers = _stickerRegex.allMatches(paragraph).toList();
      if (stickers.isEmpty) {
        children.add(_markdown(context, paragraph, body));
        continue;
      }
      final remainder = paragraph.replaceAll(_stickerRegex, '').trim();
      final standalone = remainder.isEmpty && stickers.length == 1;
      final dimension = standalone ? 96.0 : 48.0;
      if (remainder.isNotEmpty) {
        children.add(_markdown(context, remainder, body));
      }
      children.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final sticker in stickers)
              _StickerImage(
                placeholder: sticker.group(1)!,
                dimension: dimension,
              ),
          ],
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: _kParagraphSpacing,
      children: children,
    );
  }

  Widget _markdown(
    BuildContext context,
    String content,
    MarkdownStyleSheet styleSheet,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return MarkdownBody(
      data: content,
      selectable: true,
      styleSheet: styleSheet,
      // A fenced block is drawn by the app, not by the library's `pre`; see
      // [MarkdownCodeBlock].
      builders: {'pre': CodeBlockBuilder()},
      // Wrapped list items hang under their bullet with their first line rather
      // than climbing to its baseline.
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      onTapLink: (uri, href, title) async {
        // Persynth has no in-app browser surface yet; links are no-ops until
        // an external-url handler lands.
      },
      imageBuilder: (uri, title, alt) {
        final isNetworkImage = uri.scheme == 'https' || uri.scheme == 'http';
        if (!isNetworkImage) return _BrokenImage(alt: alt);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image.network(
              uri.toString(),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _BrokenImage(alt: alt),
            ),
          ),
        );
      },
      checkboxBuilder: (checked) => Icon(
        checked
            ? Symbols.check_box_rounded
            : Symbols.check_box_outline_blank_rounded,
        size: 18,
        color: checked ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// Splits a body at its blank lines, leaving fenced code blocks whole.
///
/// A blank line inside a fence is part of the code. Splitting there cuts the
/// block in half and leaves a dangling fence on each side of the seam — the one
/// shape a code block can take that is unusable — so the fences are tracked
/// first and the blank lines inside them are not boundaries. Backticks and
/// tildes both fence, indented no more than three spaces, and a fence is closed
/// by the same character at least as many times over.
List<String> _paragraphs(String text) {
  final paragraphs = <String>[];
  final lines = <String>[];
  String? fence;

  void close() {
    if (lines.isEmpty) return;
    final paragraph = lines.join('\n').trim();
    lines.clear();
    if (paragraph.isNotEmpty) paragraphs.add(paragraph);
  }

  for (final line in text.split('\n')) {
    final trimmed = line.trimLeft();
    final indent = line.length - trimmed.length;
    if (fence != null) {
      lines.add(line);
      if (trimmed.startsWith(fence) &&
          trimmed.substring(fence.length).trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    final opening = indent <= 3 ? _fenceRegex.firstMatch(trimmed) : null;
    if (opening != null) {
      fence = opening.group(1);
      lines.add(line);
      continue;
    }
    if (trimmed.isEmpty) {
      close();
      continue;
    }
    lines.add(line);
  }
  close();
  return paragraphs;
}

/// The reply's type scale, and the tones it is read in.
///
/// Two faces, as everywhere else in this app: prose is Nunito, and everything
/// the companion's *machines* say — code, the language a fence named, a table's
/// headings — is IBM Plex Mono. Nothing here names a colour of its own. The
/// accent is spent in exactly one place, the words a code block's language
/// reserves, in the tone the theme keeps for accent *text*; the rest is ink, one
/// softening of ink, and the surfaces the palette already steps between.
///
/// Public because it is the contract the reply is read under, not an
/// implementation detail of [MessageMarkdown]: a body drawn in one render and a
/// body split into paragraphs have to be spaced by the same sheet, and only a
/// test can see that they are.
MarkdownStyleSheet persynthMarkdownStyleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final base = MarkdownStyleSheet.fromTheme(theme);
  final soft = scheme.onSurfaceVariant;

  /// A rule one device pixel thick, whatever the screen does with a logical one.
  final hairline = BorderSide(
    color: scheme.outlineVariant,
    width: 1 / MediaQuery.devicePixelRatioOf(context),
  );

  TextStyle sans(
    double size, {
    double? height,
    FontWeight? weight,
    double? letterSpacing,
    Color? color,
    FontStyle? style,
  }) => TextStyle(
    fontFamily: PersynthFonts.sans,
    fontSize: size,
    height: height,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color ?? scheme.onSurface,
    fontStyle: style,
  );

  TextStyle mono(
    double size, {
    double? height,
    FontWeight? weight,
    double? letterSpacing,
    Color? color,
    Color? background,
  }) => TextStyle(
    fontFamily: PersynthFonts.mono,
    fontSize: size,
    height: height,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color ?? scheme.onSurface,
    backgroundColor: background,
  );

  return base.copyWith(
    // Prose at 15 on 1.6. A reply is a document read top to bottom, not a
    // caption under something else.
    p: sans(15, height: 1.6),
    a: TextStyle(
      color: scheme.onPrimaryContainer,
      decoration: TextDecoration.underline,
      decorationColor: scheme.onPrimaryContainer.withValues(alpha: 0.4),
      decorationThickness: 1.2,
    ),
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.w700),
    del: TextStyle(
      color: soft,
      decoration: TextDecoration.lineThrough,
      decorationColor: soft,
    ),

    // A heading in a bubble is a signpost, not a title page: one step per level,
    // and the top of the scale gets a little air above it.
    h1: sans(19, height: 1.35, weight: FontWeight.w700, letterSpacing: -0.3),
    h1Padding: const EdgeInsets.only(top: 6),
    h2: sans(17, height: 1.35, weight: FontWeight.w700, letterSpacing: -0.2),
    h2Padding: const EdgeInsets.only(top: 6),
    h3: sans(15.5, height: 1.4, weight: FontWeight.w700),
    h3Padding: const EdgeInsets.only(top: 4),
    h4: sans(15, height: 1.45, weight: FontWeight.w700),
    h5: sans(14, height: 1.45, weight: FontWeight.w700, color: soft),
    h6: sans(13, height: 1.45, weight: FontWeight.w700, color: soft),

    // Inline code is a scrap of the same paper a block is read on. It stays
    // flat: a rounded chip inside a line of prose breaks the line it sits in.
    code: mono(13, background: scheme.surface),

    // A quotation is another voice — italic, softer — marked with a bar rather
    // than a box, so it stays one column of text.
    blockquote: sans(15, height: 1.6, color: soft, style: FontStyle.italic),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: soft.withValues(alpha: 0.35), width: 2),
      ),
    ),

    // A bullet is a marker, not prose: it takes the soft tone, and the indent
    // is narrow enough to leave the measure alone.
    listIndent: 18,
    listBullet: sans(15, color: soft),
    listBulletPadding: const EdgeInsets.only(right: 6),

    blockSpacing: _kParagraphSpacing,

    // The code well: the page's own paper inside the bubble, a control hairline
    // around it, and no padding of its own — [MarkdownCodeBlock] sets its pane
    // against the well's edge and lets the code scroll under it.
    codeblockDecoration: BoxDecoration(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: scheme.outlineVariant, width: hairline.width),
    ),
    codeblockPadding: EdgeInsets.zero,

    // A rule is a hairline, not a bar: in a reply it marks a change of subject,
    // and the air blockSpacing leaves around it is what carries that.
    horizontalRuleDecoration: BoxDecoration(border: Border(top: hairline)),

    // A table carries its own grid, and a grid is rules: one hairline per row
    // edge, none between columns, and no leading padding on the first cell — so
    // the first column starts exactly where the prose above it does.
    tableHead: mono(
      11,
      weight: FontWeight.w600,
      letterSpacing: 0.5,
      color: soft,
    ),
    tableHeadAlign: TextAlign.left,
    tableBody: sans(14, height: 1.45),
    tableCellsPadding: const EdgeInsets.fromLTRB(0, 7, 14, 7),
    tableHeadCellsPadding: const EdgeInsets.fromLTRB(0, 4, 14, 8),
    tableBorder: TableBorder(
      horizontalInside: hairline,
      top: hairline,
      bottom: hairline,
    ),

    checkbox: TextStyle(color: scheme.primary),
  );
}

/// What a reply shows where a picture should have been.
class _BrokenImage extends StatelessWidget {
  const _BrokenImage({required this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Symbols.broken_image_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            alt ?? 'imageUnavailable'.tr(),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _StickerImage extends StatelessWidget {
  const _StickerImage({required this.placeholder, required this.dimension});

  final String placeholder;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: ':$placeholder:',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          _stickerUrl(placeholder),
          width: dimension,
          height: dimension,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Container(
            width: dimension,
            height: dimension,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.emoji_emotions_outlined,
              color: cs.onSurfaceVariant,
            ),
          ),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: dimension,
              height: dimension,
              alignment: Alignment.center,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress.expectedTotalBytes == null
                    ? null
                    : progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!,
              ),
            );
          },
        ),
      ),
    );
  }
}
