import 'dart:async';

/// Gives gestures and route transitions priority over speculative recording
/// work. Owners must release their token on disposal as well as on idle.
class BackgroundWorkGate {
  static final _owners = <Object>{};
  static Completer<void>? _waiting;

  static bool get isBusy => _owners.isNotEmpty;

  static void hold(Object owner) => _owners.add(owner);

  static void release(Object owner) {
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  static Future<void> get idle async {
    while (isBusy) {
      await (_waiting ??= Completer<void>()).future;
    }
  }
}
