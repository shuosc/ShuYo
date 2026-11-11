import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/background_work_gate.dart';

/// Coalesces business notifications at the viewport boundary. Requests continue
/// independently. Moving viewports freeze the current snapshot; a quiet pause
/// can publish results even if a gesture remains held. Route transitions defer
/// updates until the page becomes active again.
class RecordingListPresentation extends StatefulWidget {
  const RecordingListPresentation({
    super.key,
    required this.changes,
    required this.builder,
    this.shouldUpdateImmediately,
  });

  final Listenable changes;
  final WidgetBuilder builder;

  /// Invalidating an old search must not wait for a long scroll to end.
  final bool Function()? shouldUpdateImmediately;

  @override
  State<RecordingListPresentation> createState() =>
      _RecordingListPresentationState();
}

class _RecordingListPresentationState extends State<RecordingListPresentation> {
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;
  final _scrollingContexts = <BuildContext?>{};
  bool _dirty = true;
  bool _scheduled = false;
  bool _scrollQuiet = false;
  Timer? _quietTimer;
  Widget? _content;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant RecordingListPresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(_changed);
      widget.changes.addListener(_changed);
    }
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final navigator = Navigator.maybeOf(context);
    if (navigator != _navigator) {
      _navigator?.userGestureInProgressNotifier.removeListener(_gestureChanged);
      _navigator = navigator;
      _navigator?.userGestureInProgressNotifier.addListener(_gestureChanged);
    }
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.animation?.removeStatusListener(_animationChanged);
      _route?.secondaryAnimation?.removeStatusListener(_animationChanged);
      _route = route;
      _route?.animation?.addStatusListener(_animationChanged);
      _route?.secondaryAnimation?.addStatusListener(_animationChanged);
    }
    if (!(_route?.isCurrent ?? true)) _scrollingContexts.clear();
    _changed();
  }

  bool get _navigationReady =>
      !(_navigator?.userGestureInProgress ?? false) &&
      (_route?.isCurrent ?? true) &&
      !(_route?.animation?.isAnimating ?? false) &&
      !(_route?.secondaryAnimation?.isAnimating ?? false);

  bool get _ready =>
      _navigationReady &&
      (_scrollingContexts.isEmpty ||
          _scrollQuiet ||
          (widget.shouldUpdateImmediately?.call() ?? false));

  void _animationChanged(AnimationStatus _) => _schedule();
  void _gestureChanged() => _schedule();

  void _changed() {
    _dirty = true;
    _schedule();
  }

  void _schedule() {
    _scrollingContexts
        .removeWhere((context) => context != null && !context.mounted);
    if ((_route?.isCurrent ?? true) &&
        (!_navigationReady || _scrollingContexts.isNotEmpty)) {
      BackgroundWorkGate.hold(this);
    } else {
      BackgroundWorkGate.release(this);
    }
    if (!_dirty || _scheduled) return;
    if (!_ready) {
      if (_navigationReady && _scrollingContexts.isNotEmpty) {
        _quietTimer ??= Timer(const Duration(milliseconds: 300), () {
          _quietTimer = null;
          _scrollQuiet = true;
          _schedule();
        });
      }
      return;
    }
    _quietTimer?.cancel();
    _quietTimer = null;
    _scheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_dirty) return;
      if (!_ready) {
        _schedule();
        return;
      }
      setState(() {});
    });
  }

  bool _scrollChanged(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _scrollingContexts.add(notification.context);
      _scrollQuiet = false;
    } else if (notification is ScrollEndNotification) {
      _scrollingContexts.remove(notification.context);
    } else if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      // Debounce actual motion, rather than forcing a rebuild every 300ms in
      // the middle of a drag/fling.
      _scrollQuiet = false;
      _quietTimer?.cancel();
      _quietTimer = null;
    }
    _schedule();
    return false;
  }

  @override
  void dispose() {
    _quietTimer?.cancel();
    BackgroundWorkGate.release(this);
    widget.changes.removeListener(_changed);
    _route?.animation?.removeStatusListener(_animationChanged);
    _route?.secondaryAnimation?.removeStatusListener(_animationChanged);
    _navigator?.userGestureInProgressNotifier.removeListener(_gestureChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_content == null || _dirty && _ready) {
      if (widget.shouldUpdateImmediately?.call() ?? false) {
        _scrollingContexts.clear();
        BackgroundWorkGate.release(this);
      }
      _content = widget.builder(context);
      _dirty = false;
      _scrollQuiet = false;
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _scrollChanged,
      child: RepaintBoundary(child: _content!),
    );
  }
}
