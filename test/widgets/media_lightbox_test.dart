import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/widgets/media_lightbox.dart';

final Uint8List _bytes = File('test/fixtures/pet_image.png').readAsBytesSync();

/// Three pictures in a set, named so the chrome can be read back by name.
List<MediaLightboxItem> _items([int count = 3]) => [
  for (var i = 0; i < count; i++)
    MediaLightboxItem(
      provider: MemoryImage(_bytes),
      name: '${i + 1}.png',
      heroTag: 'test:$i',
    ),
];

/// The provider a picture actually decodes with: the viewer bounds the decode
/// to its box, which wraps the provider in a [ResizeImage].
ImageProvider _decodedBy(Image image) {
  final provider = image.image;
  return provider is ResizeImage ? provider.imageProvider : provider;
}

/// The scale the picture being looked at is drawn at.
double _scale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(
      find.byWidgetPredicate((widget) => widget is InteractiveViewer).first,
    )
    .transformationController!
    .value
    .getMaxScaleOnAxis();

/// Whether the chrome is currently stepped aside: it is faded out and, more
/// to the point, cannot be pressed.
bool _chromeIgnored(WidgetTester tester) => tester
    .widgetList<IgnorePointer>(
      find.ancestor(
        of: find.byTooltip('Close'),
        matching: find.byType(IgnorePointer),
      ),
    )
    .any((widget) => widget.ignoring);

Future<void> _openLightbox(
  WidgetTester tester, {
  int initialIndex = 0,
  int count = 3,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showMediaLightbox(
              context,
              items: _items(count),
              initialIndex: initialIndex,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Drags across the middle of the picture, the way a finger would.
Future<void> _drag(WidgetTester tester, Offset by) async {
  await tester.dragFrom(
    tester.getCenter(find.byType(MediaLightbox)),
    by,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the picture it was asked for', (tester) async {
    await _openLightbox(tester, initialIndex: 1);

    expect(find.byType(MediaLightbox), findsOneWidget);
    expect(find.text('2.png'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! Image) return false;
        final provider = _decodedBy(widget);
        return provider is MemoryImage && provider.bytes == _bytes;
      }),
      findsWidgets,
    );
  });

  testWidgets('a picture without a name is still named something', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showMediaLightbox(
                context,
                items: [MediaLightboxItem(provider: MemoryImage(_bytes))],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Image'), findsOneWidget);
    // One picture is not a set: there is no counter, and nothing to page to.
    expect(find.text('1 / 1'), findsNothing);
    expect(find.byTooltip('Next'), findsNothing);
  });

  testWidgets('a swipe turns the page, a short one does not', (tester) async {
    await _openLightbox(tester, initialIndex: 1);

    await _drag(tester, const Offset(-120, 0));
    expect(find.text('2 / 3'), findsOneWidget);

    await _drag(tester, const Offset(-520, 0));
    expect(find.text('3 / 3'), findsOneWidget);

    await _drag(tester, const Offset(520, 0));
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('there is nothing past the first and last pictures', (
    tester,
  ) async {
    await _openLightbox(tester, initialIndex: 0);

    // Nothing is before the first picture, so the drag gives instead of
    // turning — and letting go puts it back.
    await _drag(tester, const Offset(520, 0));
    expect(find.text('1 / 3'), findsOneWidget);

    // Nothing is after the last one either.
    await _drag(tester, const Offset(-520, 0));
    await _drag(tester, const Offset(-520, 0));
    expect(find.text('3 / 3'), findsOneWidget);

    await _drag(tester, const Offset(-520, 0));
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('the arrows turn the page', (tester) async {
    await _openLightbox(tester, initialIndex: 1);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('the arrow keys turn the page and escape closes', (
    tester,
  ) async {
    await _openLightbox(tester, initialIndex: 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaLightbox), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('pulling the picture down closes the viewer', (tester) async {
    await _openLightbox(tester);

    // A pull that does not get far enough is let go of, and the viewer stays.
    await _drag(tester, const Offset(0, 60));
    expect(find.byType(MediaLightbox), findsOneWidget);

    await _drag(tester, const Offset(0, 220));
    expect(find.byType(MediaLightbox), findsNothing);
  });

  testWidgets('a double-tap zooms in on the spot, and again back out', (
    tester,
  ) async {
    await _openLightbox(tester);
    expect(_scale(tester), 1);

    final centre = tester.getCenter(find.byType(MediaLightbox));
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(2.5, 0.01));

    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1, 0.01));
  });

  testWidgets('the zoom buttons step the picture and fit puts it back', (
    tester,
  ) async {
    await _openLightbox(tester);

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1.5, 0.01));

    await tester.tap(find.byTooltip('Fit to window'));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1, 0.01));

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1, 0.01));
  });

  testWidgets('a zoomed picture turns in quarter turns, back to fit', (
    tester,
  ) async {
    await _openLightbox(tester);

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(_scale(tester), closeTo(1.5, 0.01));

    await tester.tap(find.byTooltip('Rotate right'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is RotatedBox && widget.quarterTurns == 1,
      ),
      findsOneWidget,
    );
    // The transform was measured against the box the picture had before it
    // turned, so turning it puts the picture back to fit rather than
    // carrying a scale across into a box it was never about.
    expect(_scale(tester), closeTo(1, 0.01));

    await tester.tap(find.byTooltip('Rotate left'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is RotatedBox && widget.quarterTurns != 0,
      ),
      findsNothing,
    );
  });

  testWidgets('the chrome steps aside on its own and a tap calls it back', (
    tester,
  ) async {
    await _openLightbox(tester);
    expect(_chromeIgnored(tester), isFalse);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(_chromeIgnored(tester), isTrue);

    // A press where the close button was is not a press on the close button:
    // it reaches the picture, which calls the chrome back.
    await tester.tap(find.byTooltip('Close'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MediaLightbox), findsOneWidget);
    expect(_chromeIgnored(tester), isFalse);

    // Tapping the picture again hides it at once, rather than waiting.
    await tester.tapAt(tester.getCenter(find.byType(MediaLightbox)));
    await tester.pumpAndSettle();
    expect(_chromeIgnored(tester), isTrue);
  });

  testWidgets('lays out on a desk and in a pocket', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in const [Size(1440, 900), Size(420, 780)]) {
      tester.view.physicalSize = size;
      await _openLightbox(tester, initialIndex: 1);

      // The chrome is what has to fit: a window narrower than the controls
      // would be a layout error rather than a smaller picture.
      final close = tester.getRect(find.byTooltip('Close'));
      expect(close.left, greaterThanOrEqualTo(0));
      expect(close.right, lessThanOrEqualTo(size.width));
      final zoom = tester.getRect(find.byTooltip('Zoom in'));
      expect(zoom.bottom, lessThanOrEqualTo(size.height));
      expect(find.text('2 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a pinch zooms, and does not turn the page or tap', (
    tester,
  ) async {
    await _openLightbox(tester, initialIndex: 0);

    final centre = tester.getCenter(find.byType(MediaLightbox));
    final left = await tester.startGesture(centre - const Offset(20, 0));
    final right = await tester.startGesture(centre + const Offset(20, 0));
    await tester.pump();
    await left.moveTo(centre - const Offset(140, 0));
    await right.moveTo(centre + const Offset(140, 0));
    await tester.pump();
    // Two fingers are neither a tap on the chrome nor a pull on the page.
    expect(_chromeIgnored(tester), isFalse);
    expect(find.text('1 / 3'), findsOneWidget);
    await left.up();
    await right.up();
    await tester.pumpAndSettle();

    expect(_scale(tester), greaterThan(1.2));
    expect(find.text('1 / 3'), findsOneWidget);

    // Zoomed in, a swipe pans the picture instead of turning the page: the
    // way to the next one is to let go of the zoom first.
    await _drag(tester, const Offset(-520, 0));
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a broken picture says so instead of pretending', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showMediaLightbox(
                context,
                items: [
                  MediaLightboxItem(
                    provider: MemoryImage(Uint8List.fromList([1, 2, 3])),
                    name: 'broken.png',
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('broken.png'), findsWidgets);
    expect(find.text('This image did not load.'), findsOneWidget);
  });
}
