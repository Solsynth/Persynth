import 'package:flutter/material.dart';
import 'package:solar_network_foundation/solar_network_foundation.dart';

import 'package:synth_pet/auth/solar_auth_service.dart';

/// Sticker placeholder convention shared with Solar Network chat:
/// `:pack-prefix+slug:`.
const stickerPattern = r':([-\w]*\+[-\w]*):';

final _stickerRegex = RegExp(stickerPattern);
final _paragraphRegex = RegExp(
  r'(?:^|\n\s*\n)(.*?)(?=\n\s*\n|$)',
  dotAll: true,
);

String _stickerUrl(String placeholder) =>
    '${SolarAuthService.apiBase}/sphere/stickers/lookup/'
    '${Uri.encodeComponent(placeholder)}/open';

/// Renders one assistant message body.
///
/// The agent marks message boundaries with blank lines, so the text is split
/// into paragraphs. A paragraph that is only sticker placeholders renders as
/// stickers; everything else renders through [SolarMarkdownContent].
class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({super.key, required this.text, this.textStyle});

  final String text;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final match in _paragraphRegex.allMatches(text)) {
      final paragraph = (match.group(1) ?? '').trim();
      if (paragraph.isEmpty) continue;
      final stickers = _stickerRegex.allMatches(paragraph).toList();
      if (stickers.isEmpty) {
        children.add(_markdown(context, paragraph));
        continue;
      }
      final remainder = paragraph.replaceAll(_stickerRegex, '').trim();
      final standalone = remainder.isEmpty && stickers.length == 1;
      final dimension = standalone ? 96.0 : 48.0;
      if (remainder.isNotEmpty) children.add(_markdown(context, remainder));
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
      children: children,
    );
  }

  Widget _markdown(BuildContext context, String content) {
    return SolarMarkdownContent(
      content: content,
      textStyle: textStyle,
      onLinkTap: (uri) async {
        // SynthPet has no in-app browser surface yet; links are no-ops until
        // an external-url handler lands.
      },
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
            child: Icon(Icons.emoji_emotions_outlined, color: cs.outline),
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
