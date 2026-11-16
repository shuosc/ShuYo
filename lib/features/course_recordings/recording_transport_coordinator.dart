import 'dart:async';

/// Serializes transport preparation and retains native operations after a
/// timeout so a retry cannot overlap an operation that is still running.
class RecordingTransportCoordinator {
  RecordingTransportCoordinator({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;
  Future<void> _preparation = Future<void>.value();
  final _pendingOpens = <Future<void>>{};
  Future<void>? _stop;
  Future<void>? _rtcTeardown;

  Future<void> prepare(Future<void> Function() operation) {
    final work = _preparation.then((_) => operation());
    _preparation = work.catchError((Object _) {});
    return work;
  }

  void trackOpen(Future<void> work, {required bool secondary}) {
    final settled =
        work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _pendingOpens.add(settled);
    unawaited(settled.then((_) => _pendingOpens.remove(settled)));
  }

  Future<void> stopAndDrain({
    required Future<void> Function() stop,
    required Future<void> primaryQueue,
    required Future<void> secondaryQueue,
    required bool drain,
    bool waitIndefinitely = false,
  }) async {
    await _stopPlayer(stop, waitIndefinitely: waitIndefinitely);
    if (!drain) return;
    await _wait(Future.wait([primaryQueue, secondaryQueue]).then((_) {}),
        waitIndefinitely);
    // An earlier native open can outlive its Dart timeout and a subsequent
    // retry. Track every unfinished open, including both views.
    while (_pendingOpens.isNotEmpty) {
      await _wait(
          Future.wait(_pendingOpens.toList()).then((_) {}), waitIndefinitely);
    }
    // A late native open can start its decoder after the first stop.
    await _stopPlayer(stop, waitIndefinitely: waitIndefinitely);
  }

  Future<void> _wait(Future<void> work, bool waitIndefinitely) =>
      waitIndefinitely ? work : work.timeout(timeout);

  Future<void> _stopPlayer(Future<void> Function() stop,
      {required bool waitIndefinitely}) async {
    final previous = _stop;
    if (previous != null) await _wait(previous, waitIndefinitely);
    final stopWork = stop();
    _stop = stopWork.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    await _wait(stopWork, waitIndefinitely);
  }

  Future<void> waitForRtcTeardown({bool waitIndefinitely = false}) async {
    final previous = _rtcTeardown;
    if (previous == null) return;
    await _wait(previous, waitIndefinitely);
    if (identical(_rtcTeardown, previous)) _rtcTeardown = null;
  }

  Future<void> teardownRtc(Future<void> Function() dispose,
      {bool waitIndefinitely = false}) async {
    final work = dispose();
    _rtcTeardown = work;
    await _wait(work, waitIndefinitely);
    if (identical(_rtcTeardown, work)) _rtcTeardown = null;
  }
}
