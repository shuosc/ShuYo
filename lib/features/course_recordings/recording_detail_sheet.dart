// The interaction follows PiliPlus's GPL-3.0 MiniScaffold, BottomSheet_, and
// CommonSlidePage, reimplemented with public Flutter APIs:
// https://github.com/bggRGjQaUbCoE/PiliPlus/tree/main/lib/common/widgets/scaffold
// https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/pages/common/slide/common_slide_page.dart
// See the repository LICENSE for the GNU General Public License, version 3.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

typedef RecordingDetailSheetBuilder = Widget Function(VoidCallback close);

/// Opens a persistent detail panel inside the area below the video player.
abstract class RecordingDetailSheet {
  static RecordingDetailSheet of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No RecordingDetailSheetHost found in context.');
    return controller!;
  }

  static RecordingDetailSheet? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_DetailSheetScope>()
      ?.controller;

  void show(RecordingDetailSheetBuilder builder);

  void close();
}

/// Keeps detail sheets below [topInset], without a route, scrim, or rounded card.
///
/// Only the first 45 logical pixels of a sheet accept a downward sheet drag.
/// Its body owns its scroll gestures. The 30-pixel side edges also accept the
/// inward swipe used by PiliPlus's comment detail panel.
class RecordingDetailSheetHost extends StatefulWidget {
  const RecordingDetailSheetHost({
    super.key,
    required this.child,
    required this.topInset,
  });

  final Widget child;
  final double topInset;

  @override
  State<RecordingDetailSheetHost> createState() =>
      _RecordingDetailSheetHostState();
}

class _RecordingDetailSheetHostState extends State<RecordingDetailSheetHost>
    with TickerProviderStateMixin
    implements RecordingDetailSheet {
  static const _headerHeight = 45.0;
  static const _edgeWidth = 30.0;
  static const _curve = Curves.fastOutSlowIn;

  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    reverseDuration: const Duration(milliseconds: 200),
  )..addStatusListener(_onAnimationStatus);
  late final AnimationController _edgeAnimation = AnimationController(
    vsync: this,
    reverseDuration: const Duration(milliseconds: 500),
  );
  late final Listenable _animations = Listenable.merge([
    _animation,
    _edgeAnimation,
  ]);
  late final _HeaderDragRecognizer _verticalDrag = _HeaderDragRecognizer(
    debugOwner: this,
    headerHeight: _headerHeight,
  )
    ..onStart = _onVerticalStart
    ..onUpdate = _onVerticalUpdate
    ..onEnd = _onVerticalEnd
    ..onCancel = _onVerticalCancel
    ..onlyAcceptDragOnThreshold = true;
  late final _EdgeDragRecognizer _horizontalDrag = _EdgeDragRecognizer(
    debugOwner: this,
    isAllowed: (dx) {
      if (dx <= _edgeWidth) {
        _edgeFromRight = false;
        return true;
      }
      if (dx >= _sheetWidth - _edgeWidth) {
        _edgeFromRight = true;
        return true;
      }
      return false;
    },
  )
    ..onStart = _onHorizontalStart
    ..onUpdate = _onHorizontalUpdate
    ..onEnd = _onHorizontalEnd
    ..onCancel = _onHorizontalCancel;

  Curve _animationCurve = _curve;
  Widget? _sheet;
  LocalHistoryEntry? _historyEntry;
  double _sheetHeight = 0;
  double _sheetWidth = 0;
  double? _horizontalStart;
  bool _edgeFromRight = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    _verticalDrag.gestureSettings = settings;
    _horizontalDrag.gestureSettings = settings;
  }

  @override
  void show(RecordingDetailSheetBuilder builder) {
    if (!mounted) return;
    _removeHistoryEntry();
    _animation.stop();
    _edgeAnimation.stop();
    _animation.value = 0;
    _edgeAnimation.value = 0;
    _animationCurve = _curve;
    _horizontalStart = null;
    setState(() => _sheet = builder(close));

    final route = ModalRoute.of(context);
    if (route != null) {
      late final LocalHistoryEntry entry;
      entry = LocalHistoryEntry(onRemove: () {
        if (_historyEntry != entry) return;
        _historyEntry = null;
        _dismiss();
      });
      _historyEntry = entry;
      route.addLocalHistoryEntry(entry);
    }
    _animation.forward();
  }

  @override
  void close() {
    if (!mounted || _sheet == null) return;
    _removeHistoryEntry();
    _dismiss();
  }

  void _removeHistoryEntry() {
    final entry = _historyEntry;
    _historyEntry = null;
    entry?.remove();
  }

  void _dismiss() {
    if (_sheet == null) return;
    if (_animation.isDismissed) {
      setState(() => _sheet = null);
      return;
    }
    _animation.reverse();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted && _sheet != null) {
      _removeHistoryEntry();
      setState(() => _sheet = null);
    }
  }

  void _onVerticalStart(DragStartDetails details) {
    if (_animation.status == AnimationStatus.reverse) return;
    _animationCurve = Curves.linear;
  }

  void _onVerticalUpdate(DragUpdateDetails details) {
    if (_animation.status == AnimationStatus.reverse || _sheetHeight <= 0) {
      return;
    }
    _animation.value -= details.primaryDelta! / _sheetHeight;
  }

  void _onVerticalEnd(DragEndDetails details) {
    if (_animation.status == AnimationStatus.reverse) return;
    _animationCurve = Split(_animation.value, endCurve: _curve);
    if (details.velocity.pixelsPerSecond.dy > 700 || _animation.value < .5) {
      close();
    } else {
      _animation.forward();
    }
  }

  void _onVerticalCancel() {
    if (_animation.status == AnimationStatus.reverse) return;
    _animationCurve = Split(_animation.value, endCurve: _curve);
    _animation.forward();
  }

  void _onHorizontalStart(DragStartDetails details) {
    _edgeAnimation.stop();
    _horizontalStart = details.localPosition.dx;
  }

  void _onHorizontalUpdate(DragUpdateDetails details) {
    final start = _horizontalStart;
    if (start == null || _sheetWidth <= 0) return;
    final distance = _edgeFromRight
        ? start - details.localPosition.dx
        : details.localPosition.dx - start;
    _edgeAnimation.value = math.max(0, distance) / _sheetWidth;
  }

  void _onHorizontalEnd(DragEndDetails details) => _finishHorizontalDrag();

  void _onHorizontalCancel() => _finishHorizontalDrag();

  void _finishHorizontalDrag() {
    final start = _horizontalStart;
    if (start == null) return;
    final fromEdge = _edgeFromRight ? _sheetWidth - start : start;
    if (_edgeAnimation.value * _sheetWidth + fromEdge >= 100) {
      close();
    } else {
      _edgeAnimation.reverse();
    }
    _horizontalStart = null;
  }

  @override
  void dispose() {
    _removeHistoryEntry();
    _verticalDrag.dispose();
    _horizontalDrag.dispose();
    _animation.dispose();
    _edgeAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _DetailSheetScope(
        controller: this,
        child: LayoutBuilder(builder: (context, constraints) {
          final top = widget.topInset.clamp(0.0, constraints.maxHeight);
          _sheetHeight = constraints.maxHeight - top;
          _sheetWidth = constraints.maxWidth;
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_sheet case final sheet?)
                Positioned(
                  top: top,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: _animations,
                      builder: (context, child) {
                        final visible =
                            _animationCurve.transform(_animation.value) *
                                (1 - _edgeAnimation.value);
                        return FractionalTranslation(
                          translation: Offset(0, 1 - visible),
                          child: child,
                        );
                      },
                      child: RepaintBoundary(
                        child: Listener(
                          onPointerDown: (event) {
                            _verticalDrag.addPointer(event);
                            _horizontalDrag.addPointer(event);
                          },
                          child: Semantics(
                            key: const ValueKey('recording-detail-sheet'),
                            container: true,
                            onDismiss: close,
                            child: sheet,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        }),
      );
}

class _DetailSheetScope extends InheritedWidget {
  const _DetailSheetScope({required this.controller, required super.child});

  final RecordingDetailSheet controller;

  @override
  bool updateShouldNotify(_DetailSheetScope oldWidget) =>
      controller != oldWidget.controller;
}

class _HeaderDragRecognizer extends VerticalDragGestureRecognizer {
  _HeaderDragRecognizer(
      {required super.debugOwner, required this.headerHeight});

  final double headerHeight;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event.localPosition.dy < headerHeight && super.isPointerAllowed(event);
}

class _EdgeDragRecognizer extends HorizontalDragGestureRecognizer {
  _EdgeDragRecognizer({required super.debugOwner, required this.isAllowed});

  final bool Function(double dx) isAllowed;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      isAllowed(event.localPosition.dx) && super.isPointerAllowed(event);
}
