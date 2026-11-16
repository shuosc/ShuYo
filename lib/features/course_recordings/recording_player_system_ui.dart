import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class RecordingPlayerSystemUi {
  List<DeviceOrientation>? _orientations;
  SystemUiMode? _mode;
  bool _released = false;

  void lockPortrait() {
    if (_released) return;
    _setOrientations(const [DeviceOrientation.portraitUp]);
  }

  void enterFullscreen() {
    if (_released) return;
    _setOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _setMode(SystemUiMode.immersiveSticky);
  }

  void exitFullscreen() {
    if (_released) return;
    _setOrientations(const [DeviceOrientation.portraitUp]);
    _setMode(SystemUiMode.edgeToEdge);
  }

  void release() {
    if (_released) return;
    _released = true;
    _setOrientations(const []);
    _setMode(SystemUiMode.edgeToEdge);
  }

  void _setOrientations(List<DeviceOrientation> orientations) {
    if (listEquals(_orientations, orientations)) return;
    _orientations = orientations;
    unawaited(SystemChrome.setPreferredOrientations(orientations)
        .onError((Object error, StackTrace stackTrace) {
      if (identical(_orientations, orientations)) _orientations = null;
      debugPrint('Recording player orientation update failed: $error');
    }));
  }

  void _setMode(SystemUiMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    unawaited(SystemChrome.setEnabledSystemUIMode(mode)
        .onError((Object error, StackTrace stackTrace) {
      if (_mode == mode) _mode = null;
      debugPrint('Recording player system UI update failed: $error');
    }));
  }
}
