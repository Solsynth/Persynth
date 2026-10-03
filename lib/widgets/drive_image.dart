import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/personality/personality_service.dart';

/// A drive file's picture, drawn from the id alone, filling the space it is
/// given.
///
/// The composer's strip and a sent turn both know their image only by the drive
/// id: the file it was picked from may be a path this device no longer holds,
/// and a replayed thread has nothing but ids. So the picture comes over the
/// network, from the endpoint that serves the file itself.
///
/// That endpoint is behind the account, so the request carries the bearer
/// token — which is why this is a widget of its own rather than an
/// `Image.network` at each call site: the token is read asynchronously, and
/// until it arrives the space shows [DriveFilePlaceholder] rather than a
/// broken image.
class DriveImage extends ConsumerWidget {
  const DriveImage({super.key, required this.fileId, this.fit = BoxFit.cover});

  /// The drive file to draw. Empty is a file with no id yet — an upload that
  /// has not landed — and draws the placeholder.
  final String fileId;

  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final token = ref.watch(solarAccessTokenProvider).value;
    if (fileId.isEmpty || token == null || token.trim().isEmpty) {
      return const DriveFilePlaceholder();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final ratio = MediaQuery.devicePixelRatioOf(context);
        return Image.network(
          PersonalityCoreService.driveFileUrl(
            ref.watch(personalityDriveBaseUrlProvider),
            fileId,
          ),
          headers: {'Authorization': 'Bearer ${token.trim()}'},
          fit: fit,
          // The picture is drawn at the size of its box: decoding the whole
          // file for a thumbnail would spend megabytes on a hundred pixels.
          cacheWidth: side.isFinite ? (side * ratio).round() : null,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const DriveFilePlaceholder(),
          errorBuilder: (context, _, _) => const DriveFilePlaceholder(),
        );
      },
    );
  }
}

/// The neutral stand-in for a drive file: what a preview shows while its token
/// or its bytes are still on their way, and what it leaves behind when the file
/// cannot be drawn at all — a deleted file, a refused request, no session.
///
/// It fills its box, so the tile that holds it keeps the shape the picture
/// will have.
class DriveFilePlaceholder extends StatelessWidget {
  const DriveFilePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Icon(
            Symbols.image_rounded,
            size: (constraints.biggest.shortestSide * 0.4).clamp(12.0, 48.0),
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
