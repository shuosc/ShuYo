import 'dart:async';

import 'package:flutter/animation.dart';

/// Defers native decoder creation while the route is sliding onto the screen.
///
/// Network requests can run before [ready]; only expensive foreground work
/// waits. This uses the route's actual animation rather than a guessed delay.
class RecordingRouteWorkGate {
  Animation<double>? _animation;
  Completer<bool>? _pending;
  bool _disposed = false;

  void attach(Animation<double>? animation) {
    if (_disposed || identical(animation, _animation)) return;
    _release(false);
    _animation = animation;
  }

  /// False when entry was cancelled or the owning page was disposed.
  Future<bool> get ready {
    if (_disposed || _animation?.status == AnimationStatus.dismissed) {
      return Future<bool>.value(false);
    }
    if (_animation == null || _animation!.status == AnimationStatus.completed) {
      return Future<bool>.value(true);
    }
    if (_pending case final pending?) return pending.future;
    final pending = _pending = Completer<bool>();
    _animation!.addStatusListener(_onStatus);
    return pending.future;
  }

  void _onStatus(AnimationStatus status) {
    // An interactive back gesture can reverse and then resume the entry.
    // Only terminal states decide whether native work may start.
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _release(status == AnimationStatus.completed);
    }
  }

  void _release(bool allowWork) {
    _animation?.removeStatusListener(_onStatus);
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(allowWork);
  }

  void dispose() {
    _disposed = true;
    _release(false);
    _animation = null;
  }
}
