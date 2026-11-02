import 'package:flutter/material.dart';

/// Coalesces business notifications at the viewport boundary. Requests continue
/// independently, but list insertions wait for scrolling and route transitions
/// to finish instead of relaying every response into an in-flight gesture.
class RecordingListPresentation extends StatefulWidget {
  const RecordingListPresentation({
    super.key,
    required this.changes,
    required this.builder,
  });

  final Listenable changes;
  final WidgetBuilder builder;

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

  bool get _ready =>
      _scrollingContexts.isEmpty &&
      !(_navigator?.userGestureInProgress ?? false) &&
      (_route?.isCurrent ?? true) &&
      !(_route?.animation?.isAnimating ?? false) &&
      !(_route?.secondaryAnimation?.isAnimating ?? false);

  void _animationChanged(AnimationStatus _) => _schedule();
  void _gestureChanged() => _schedule();

  void _changed() {
    _dirty = true;
    _schedule();
  }

  void _schedule() {
    if (!_dirty || _scheduled || !_ready) return;
    _scheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_dirty || !_ready) return;
      setState(() {});
    });
  }

  bool _scrollChanged(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _scrollingContexts.add(notification.context);
    } else if (notification is ScrollEndNotification) {
      _scrollingContexts.remove(notification.context);
      _schedule();
    }
    return false;
  }

  @override
  void dispose() {
    widget.changes.removeListener(_changed);
    _route?.animation?.removeStatusListener(_animationChanged);
    _route?.secondaryAnimation?.removeStatusListener(_animationChanged);
    _navigator?.userGestureInProgressNotifier.removeListener(_gestureChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_content == null || _dirty && _ready) {
      _content = widget.builder(context);
      _dirty = false;
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _scrollChanged,
      child: _content!,
    );
  }
}
