import 'package:flutter/material.dart';

import '../../core/background_work_gate.dart';

/// Observes the real route/gesture lifecycle without rebuilding its child on
/// every animation tick. Hidden routes never retain a global work blocker.
class BackgroundWorkBoundary extends StatefulWidget {
  const BackgroundWorkBoundary({super.key, required this.child});
  final Widget child;

  @override
  State<BackgroundWorkBoundary> createState() => _BackgroundWorkBoundaryState();
}

class _BackgroundWorkBoundaryState extends State<BackgroundWorkBoundary> {
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;
  final _scrolls = <BuildContext?>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_animationChanged);
      _route?.secondaryAnimation?.removeStatusListener(_animationChanged);
      _route = route;
      route?.animation?.addStatusListener(_animationChanged);
      route?.secondaryAnimation?.addStatusListener(_animationChanged);
    }
    final navigator = Navigator.maybeOf(context);
    if (!identical(navigator, _navigator)) {
      _navigator?.userGestureInProgressNotifier.removeListener(_changed);
      _navigator = navigator;
      navigator?.userGestureInProgressNotifier.addListener(_changed);
    }
    _changed();
  }

  void _animationChanged(AnimationStatus _) => _changed();

  void _changed() {
    final current = _route?.isCurrent ?? true;
    _scrolls.removeWhere((context) => context != null && !context.mounted);
    if (!current) _scrolls.clear();
    final busy = current &&
        (_scrolls.isNotEmpty ||
            (_route?.animation?.isAnimating ?? false) ||
            (_route?.secondaryAnimation?.isAnimating ?? false) ||
            (_navigator?.userGestureInProgress ?? false));
    if (busy) {
      BackgroundWorkGate.hold(this);
    } else {
      BackgroundWorkGate.release(this);
    }
  }

  bool _scroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _scrolls.add(notification.context);
    } else if (notification is ScrollEndNotification) {
      _scrolls.remove(notification.context);
    }
    _changed();
    return false;
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_animationChanged);
    _route?.secondaryAnimation?.removeStatusListener(_animationChanged);
    _navigator?.userGestureInProgressNotifier.removeListener(_changed);
    BackgroundWorkGate.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
          onNotification: _scroll, child: widget.child);
}
