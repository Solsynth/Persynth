import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:material_symbols_icons/symbols.dart';

/// One picture the lightbox can show: where its bytes come from, what to call
/// it, and the [Hero] tag it shares with the thumbnail it was opened from.
@immutable
class MediaLightboxItem {
  const MediaLightboxItem({required this.provider, this.name, this.heroTag});

  /// The picture itself. A file the reader picked is a [FileImage]; a drive
  /// file is a [NetworkImage] carrying the bearer token, so the viewer draws
  /// the same bytes the thumbnail did.
  final ImageProvider provider;

  /// What the picture is called, shown over it. Null for one that arrived
  /// without a name.
  final String? name;

  /// The tag shared with the thumbnail this picture grows out of. Null opens
  /// without a Hero, which is what a markdown image or a pasted link wants.
  final String? heroTag;
}

/// Opens the full-screen viewer over [items], starting at [initialIndex].
///
/// The route is not opaque: the app stays mounted behind it, which is what
/// lets a downward drag uncover the conversation underneath instead of
/// fading to black.
Future<void> showMediaLightbox(
  BuildContext context, {
  required List<MediaLightboxItem> items,
  int initialIndex = 0,
}) {
  if (items.isEmpty) return Future<void>.value();
  final index = initialIndex.clamp(0, items.length - 1);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: null,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) =>
          MediaLightbox(items: items, initialIndex: index),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// The lightbox: one picture at a time on black, the rest of the set a swipe
/// away, and chrome that gets out of the way.
///
/// Everything the reader does with a pointer is read from raw pointer events
/// rather than from gesture recognisers. The zooming [InteractiveViewer] under
/// every page claims drags for itself — it has to, or it could not pan a
/// zoomed picture — and a page view or a dismissible wrapper built on
/// recognisers would lose that contest instead of sharing the drag with it.
/// Tracking the pointer directly keeps one conversation: the picture pans when
/// it is zoomed, and the page turns or the viewer closes when it is not.
class MediaLightbox extends StatefulWidget {
  const MediaLightbox({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  final List<MediaLightboxItem> items;
  final int initialIndex;

  @override
  State<MediaLightbox> createState() => _MediaLightboxState();
}

/// How far down a picture has to be pulled before letting it go closes the
/// viewer, and how fast a flick counts as letting it go.
const double _kDismissDistance = 110;
const double _kDismissVelocity = 800;

/// How far across a picture has to be pulled before letting it go turns the
/// page, and how fast a flick counts.
const double _kPageFraction = 1 / 3;
const double _kPageVelocity = 700;

/// Chrome hides itself after this long without a touch.
const Duration _kChromeHideDelay = Duration(seconds: 3);

/// Two taps closer together than this, close enough on screen, are one
/// double-tap: zoom in on the spot, or back out to fit.
const Duration _kDoubleTapWindow = Duration(milliseconds: 300);

/// The zoom a double-tap goes to, and what a zoom button steps by.
const double _kDoubleTapZoom = 2.5;
const double _kZoomStep = 0.5;

/// What the viewer allows: no further out than the whole picture, six times in.
const double _kMinScale = 1;
const double _kMaxScale = 6;

/// The widest a picture is ever decoded at, whatever the window says.
///
/// Each picture is decoded at twice the box it is drawn in, so that zooming
/// into it shows more than a stretched thumbnail — but three pictures are
/// mounted at once (the one being looked at and the two beside it), and an
/// unbounded multiple of a large window would spend hundreds of megabytes on
/// three frames of a conversation.
const int _kDecodedWidthCeiling = 2560;

/// Which way the finger that is down has decided to go. A drag has to commit
/// to an axis before it does anything, so a slightly crooked horizontal swipe
/// never tears the picture off the screen.
enum _DragAxis { undecided, horizontal, vertical }

/// A tap waiting to find out whether it is the first half of a double-tap.
class _TapRecord {
  const _TapRecord(this.time, this.position);

  final DateTime time;
  final Offset position;
}

class _MediaLightboxState extends State<MediaLightbox>
    with TickerProviderStateMixin {
  /// One transform per picture, so a picture the reader zoomed into is still
  /// zoomed when they swipe back to it.
  late final List<TransformationController> _transforms = [
    for (final _ in widget.items) TransformationController(),
  ];

  /// One rotation per picture, in quarter turns, so a sideways photograph
  /// stays sideways while the reader moves through the set.
  late final List<int> _quarterTurns = List.filled(widget.items.length, 0);

  late int _index = widget.initialIndex;

  /// The page's offset while a finger is dragging it: across for a page turn,
  /// down for a close.
  Offset _offset = Offset.zero;
  _DragAxis _axis = _DragAxis.undecided;
  int _pointers = 0;
  bool _pinching = false;
  Offset _downPosition = Offset.zero;
  bool _moved = false;
  VelocityTracker _velocity = VelocityTracker.withKind(PointerDeviceKind.touch);
  _TapRecord? _lastTap;

  /// The box the viewer was last laid out in, which is what drag distances are
  /// measured against.
  Size _viewport = Size.zero;

  bool _zoomed = false;
  bool _chromeVisible = true;
  Timer? _chromeTimer;

  late final AnimationController _settleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final AnimationController _zoomController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Offset _settleFrom = Offset.zero;
  Offset _settleTo = Offset.zero;
  VoidCallback? _settleDone;
  Matrix4? _zoomStarts;
  Matrix4? _zoomEnds;

  @override
  void initState() {
    super.initState();
    for (final transform in _transforms) {
      transform.addListener(_onTransformChanged);
    }
    _settleController.addListener(_onSettleTick);
    _settleController.addStatusListener(_onSettleStatus);
    _zoomController.addListener(_onZoomTick);
    _armChromeTimer();
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    for (final transform in _transforms) {
      transform.removeListener(_onTransformChanged);
      transform.dispose();
    }
    _settleController.dispose();
    _zoomController.dispose();
    super.dispose();
  }

  MediaLightboxItem get _item => widget.items[_index];

  double get _scale => _transforms[_index].value.getMaxScaleOnAxis();

  /// Whether the picture being looked at is past its box, which is when
  /// dragging moves it rather than turning the page or closing the viewer.
  bool get _isZoomed => _scale > 1.001;

  void _onTransformChanged() {
    final zoomed = _isZoomed;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onSettleTick() {
    setState(() {
      _offset = Offset.lerp(
        _settleFrom,
        _settleTo,
        Curves.easeOutCubic.transform(_settleController.value),
      )!;
    });
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final done = _settleDone;
    _settleDone = null;
    setState(() => _offset = Offset.zero);
    done?.call();
  }

  void _onZoomTick() {
    final from = _zoomStarts;
    final to = _zoomEnds;
    if (from == null || to == null) return;
    _transforms[_index].value = Matrix4Tween(
      begin: from,
      end: to,
    ).lerp(_zoomController.value);
  }

  /// Where the page should slide to, and what to do once it is there.
  void _settle(Offset to, {VoidCallback? done}) {
    _settleFrom = _offset;
    _settleTo = to;
    _settleDone = done;
    _settleController.forward(from: 0);
  }

  // Chrome.

  void _armChromeTimer() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(_kChromeHideDelay, () {
      if (!mounted || !_chromeVisible) return;
      setState(() => _chromeVisible = false);
    });
  }

  void _revealChrome() {
    _chromeTimer?.cancel();
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _armChromeTimer();
  }

  void _toggleChrome() {
    if (_chromeVisible) {
      _chromeTimer?.cancel();
      setState(() => _chromeVisible = false);
    } else {
      _revealChrome();
    }
  }

  // Paging.

  void _pageTo(int index, {bool animate = true}) {
    final target = index.clamp(0, widget.items.length - 1);
    if (target == _index) return;
    final steps = target - _index;
    _revealChrome();
    if (!animate) {
      setState(() => _index = target);
      return;
    }
    _settle(
      Offset(-steps * _viewport.width, 0),
      done: () => setState(() => _index = target),
    );
  }

  void _pageBy(int step) => _pageTo(_index + step);

  // Zoom.

  /// Scales the current picture about [anchor] by [factor], keeping whatever
  /// is under the anchor where it is.
  Matrix4 _scaledAbout(Offset anchor, double factor) {
    final move = Matrix4.identity()
      ..translateByDouble(anchor.dx, anchor.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-anchor.dx, -anchor.dy, 0, 1);
    return move * _transforms[_index].value.clone();
  }

  void _animateTransformTo(Matrix4 target) {
    final from = _transforms[_index].value.clone();
    if (from == target) return;
    _zoomStarts = from;
    _zoomEnds = target;
    _zoomController.forward(from: 0);
  }

  void _zoomTo(double scale, {Offset? anchor}) {
    final current = _scale;
    final target = scale.clamp(_kMinScale, _kMaxScale);
    if ((target - current).abs() < 0.001) return;
    _revealChrome();
    final at = anchor ?? _viewport.center(Offset.zero);
    _animateTransformTo(_scaledAbout(at, target / current));
  }

  void _zoomBy(double delta) => _zoomTo(_scale + delta);

  void _toggleZoom(Offset anchor) {
    _revealChrome();
    if (_isZoomed) {
      _zoomTo(_kMinScale);
    } else {
      _zoomTo(_kDoubleTapZoom, anchor: anchor);
    }
  }

  void _fit() => _zoomTo(_kMinScale);

  /// Turns the picture by a quarter, and puts it back to fit: the transform
  /// the reader was carrying was measured against the box the picture had
  /// before it turned, and there is no honest way to carry it across.
  void _rotate(int quarters) {
    _revealChrome();
    _zoomController.stop();
    setState(() {
      _quarterTurns[_index] = (_quarterTurns[_index] + quarters) % 4;
      _transforms[_index].value = Matrix4.identity();
    });
  }

  // Pointers.

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    if (_pointers > 1) {
      // A second finger is a pinch, not a drag: the whole gesture is handed
      // back to the picture, and whatever is left of it after one finger
      // lifts is not a drag either.
      _pinching = true;
      _axis = _DragAxis.undecided;
      _moved = false;
      return;
    }
    _downPosition = event.localPosition;
    _moved = false;
    _axis = _DragAxis.undecided;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    _settleController.stop();
    _zoomController.stop();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_pointers != 1 || _pinching || _isZoomed) return;
    _velocity.addPosition(event.timeStamp, event.localPosition);
    final travelled = event.localPosition - _downPosition;
    if (!_moved) {
      if (travelled.distance < kTouchSlop / 2) return;
      _moved = true;
    }
    if (_axis == _DragAxis.undecided) {
      _axis = travelled.dx.abs() >= travelled.dy.abs()
          ? _DragAxis.horizontal
          : _DragAxis.vertical;
    }
    final width = _viewport.width;
    setState(() {
      if (_axis == _DragAxis.horizontal) {
        var dx = travelled.dx;
        final pastTheEnd =
            (_index == 0 && dx > 0) ||
            (_index == widget.items.length - 1 && dx < 0);
        // Nothing beyond the first or last picture: the drag shows the edge
        // gives, rather than pretending there is another page there.
        if (pastTheEnd) dx *= 0.35;
        _offset = Offset(dx, 0);
      } else {
        _offset = Offset(0, travelled.dy.clamp(-width * 2, width * 2));
      }
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_pointers > 0) _pointers--;
    if (_pointers > 0) return;
    final pinched = _pinching;
    _pinching = false;
    if (!_moved) {
      // A pinch is not a tap: nothing was tapped, and the chrome is not the
      // thing that was being pinched.
      if (!pinched) _handleTap(event.localPosition);
      // A page caught mid-turn when the finger came down is let go of.
      if (_offset != Offset.zero) _settle(Offset.zero);
      return;
    }
    final velocity = _velocity.getVelocity();
    if (_axis == _DragAxis.horizontal) {
      final width = _viewport.width;
      final dir = _offset.dx < 0 ? 1 : -1;
      final fling = velocity.pixelsPerSecond.dx;
      final far =
          _offset.dx.abs() > width * _kPageFraction ||
          fling.abs() > _kPageVelocity;
      final hasNeighbour = dir > 0
          ? _index < widget.items.length - 1
          : _index > 0;
      if (far && hasNeighbour) {
        _settle(
          Offset(-dir * width, 0),
          done: () => setState(() => _index += dir),
        );
      } else {
        _settle(Offset.zero);
      }
    } else if (_axis == _DragAxis.vertical) {
      final fling = velocity.pixelsPerSecond.dy;
      if (_offset.dy > _kDismissDistance || fling > _kDismissVelocity) {
        Navigator.of(context).pop();
      } else {
        _settle(Offset.zero);
      }
    }
    _axis = _DragAxis.undecided;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_pointers > 0) _pointers--;
    if (_pointers > 0) return;
    _pinching = false;
    _axis = _DragAxis.undecided;
    _settle(Offset.zero);
  }

  /// A tap toggles the chrome; two of them in quick succession on the same
  /// spot zoom instead. The first tap of a double-tap toggles the chrome and
  /// the second toggles it back, which reads as nothing having happened —
  /// which is right, since the tap was not about the chrome.
  void _handleTap(Offset position) {
    final now = DateTime.now();
    final previous = _lastTap;
    _lastTap = _TapRecord(now, position);
    if (previous != null &&
        now.difference(previous.time) < _kDoubleTapWindow &&
        (position - previous.position).distance < 40) {
      _lastTap = null;
      _toggleZoom(position);
      return;
    }
    _toggleChrome();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _pageBy(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _pageBy(1);
    } else if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _zoomBy(_kZoomStep);
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _zoomBy(-_kZoomStep);
    } else if (key == LogicalKeyboardKey.keyF) {
      _fit();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _viewport = constraints.biggest;
            final padding = MediaQuery.paddingOf(context);
            // Pulled down far enough, the black behind the picture gives way
            // to the conversation it was opened over.
            final dragged = (_offset.dy / (_kDismissDistance * 3)).clamp(
              0.0,
              1.0,
            );
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 1 - dragged),
                  ),
                  Transform.translate(
                    offset: _offset,
                    child: _buildPages(context),
                  ),
                  _buildChrome(context, padding),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The picture being looked at, and the two beside it: only those are
  /// built, since a set of a hundred photographs is still one swipe at a
  /// time.
  Widget _buildPages(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Twice the box, so a zoomed picture still has pixels to spend, and never
    // past the ceiling above or the file's own size, which the decoder has no
    // more of.
    final decodedWidth = (_viewport.width * ratio * 2)
        .round()
        .clamp(1, _kDecodedWidthCeiling);
    final width = _viewport.width;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var distance = -1; distance <= 1; distance++)
          if (_index + distance >= 0 &&
              _index + distance < widget.items.length)
            Positioned(
              left: distance * width,
              top: 0,
              bottom: 0,
              width: width,
              child: _MediaPage(
                item: widget.items[_index + distance],
                transform: _transforms[_index + distance],
                quarterTurns: _quarterTurns[_index + distance],
                decodedWidth: decodedWidth,
                interactive: distance == 0,
                heroTag: _index + distance == widget.initialIndex
                    ? widget.items[_index + distance].heroTag
                    : null,
              ),
            ),
      ],
    );
  }

  Widget _buildChrome(BuildContext context, EdgeInsets padding) {
    final item = _item;
    final name = item.name?.trim() ?? '';
    return IgnorePointer(
      ignoring: !_chromeVisible,
      child: AnimatedOpacity(
        opacity: _chromeVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: padding.top + 96,
              child: const _ChromeGradient(top: true),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: padding.bottom + 112,
              child: const _ChromeGradient(top: false),
            ),
            Positioned(
              top: padding.top + 8,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  _ChromeIconButton(
                    icon: Symbols.close_rounded,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Gap(10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name.isEmpty ? 'Image' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (widget.items.length > 1)
                          Text(
                            '${_index + 1} / ${widget.items.length}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.items.length > 1) ...[
              if (_index > 0)
                Positioned(
                  left: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _ChromeIconButton(
                      icon: Symbols.chevron_left,
                      tooltip: 'Previous',
                      size: 44,
                      iconSize: 28,
                      onPressed: () => _pageBy(-1),
                    ),
                  ),
                ),
              if (_index < widget.items.length - 1)
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _ChromeIconButton(
                      icon: Symbols.chevron_right,
                      tooltip: 'Next',
                      size: 44,
                      iconSize: 28,
                      onPressed: () => _pageBy(1),
                    ),
                  ),
                ),
            ],
            Positioned(
              left: 16,
              right: 16,
              bottom: padding.bottom + 16,
              child: Row(
                children: [
                  _ChromePill(
                    children: [
                      _ChromeIconButton(
                        icon: Symbols.zoom_out,
                        tooltip: 'Zoom out',
                        onPressed: _scale <= _kMinScale
                            ? null
                            : () => _zoomBy(-_kZoomStep),
                      ),
                      _ChromeIconButton(
                        icon: Symbols.zoom_in,
                        tooltip: 'Zoom in',
                        onPressed: _scale >= _kMaxScale
                            ? null
                            : () => _zoomBy(_kZoomStep),
                      ),
                      _ChromeIconButton(
                        icon: Symbols.fit_screen,
                        tooltip: 'Fit to window',
                        onPressed: _isZoomed ? _fit : null,
                      ),
                      _ChromeIconButton(
                        icon: Symbols.rotate_left,
                        tooltip: 'Rotate left',
                        onPressed: () => _rotate(3),
                      ),
                      _ChromeIconButton(
                        icon: Symbols.rotate_right,
                        tooltip: 'Rotate right',
                        onPressed: () => _rotate(1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One picture on the black: zoomable while it is the one being looked at,
/// and drawn at fit otherwise.
class _MediaPage extends StatelessWidget {
  const _MediaPage({
    required this.item,
    required this.transform,
    required this.quarterTurns,
    required this.decodedWidth,
    required this.interactive,
    this.heroTag,
  });

  final MediaLightboxItem item;
  final TransformationController transform;
  final int quarterTurns;
  final int decodedWidth;
  final bool interactive;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final decoded = ResizeImage(item.provider, width: decodedWidth);
    Widget picture = Image(
      image: decoded,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: item.name,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _LoadingNotification(event: progress),
      errorBuilder: (context, _, _) => _PictureRefused(name: item.name),
    );
    final tag = heroTag;
    if (tag != null) picture = Hero(tag: tag, child: picture);
    return IgnorePointer(
      ignoring: !interactive,
      child: RotatedBox(
        quarterTurns: quarterTurns,
        child: InteractiveViewer(
          transformationController: transform,
          minScale: _kMinScale,
          maxScale: _kMaxScale,
          clipBehavior: Clip.none,
          child: picture,
        ),
      ),
    );
  }
}

/// How much of a picture has arrived, over it.
class _LoadingNotification extends StatelessWidget {
  const _LoadingNotification({required this.event});

  final ImageChunkEvent? event;

  @override
  Widget build(BuildContext context) {
    final loaded = event?.cumulativeBytesLoaded;
    final total = event?.expectedTotalBytes;
    final progress = (loaded != null && total != null && total > 0)
        ? loaded / total
        : null;
    return Center(
      child: _ChromePill(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          if (progress != null) ...[
            const Gap(10),
            Text(
              '${(progress * 100).round()}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a picture the viewer cannot draw leaves behind: enough of its name to
/// know which one failed, and no pretence that it is still coming.
class _PictureRefused extends StatelessWidget {
  const _PictureRefused({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final label = name?.trim() ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.broken_image_rounded,
              size: 56,
              color: Colors.white.withValues(alpha: 0.54),
            ),
            const Gap(12),
            Text(
              label.isEmpty ? 'This image did not load.' : label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 15,
              ),
            ),
            if (label.isNotEmpty) ...[
              const Gap(4),
              Text(
                'This image did not load.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The shade the chrome sits on at the top and the bottom of the viewer.
class _ChromeGradient extends StatelessWidget {
  const _ChromeGradient({required this.top});

  final bool top;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.65),
              Colors.black.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded black surface holding a row of controls.
class _ChromePill extends StatelessWidget {
  const _ChromePill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// One control on the chrome: white on the shade, quiet when it has nothing
/// to do.
class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 40,
    this.iconSize = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
      ),
      icon: Icon(
        icon,
        size: iconSize,
        color: Colors.white.withValues(alpha: enabled ? 1 : 0.4),
      ),
    );
  }
}
