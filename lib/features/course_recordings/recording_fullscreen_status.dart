import 'dart:async';

import 'package:flutter/material.dart';

class RecordingFullscreenStatus extends StatefulWidget {
  const RecordingFullscreenStatus({
    super.key,
    this.showClock = true,
    this.active = true,
    this.clock,
  });

  final bool showClock;
  final bool active;
  final DateTime Function()? clock;

  @override
  State<RecordingFullscreenStatus> createState() =>
      _RecordingFullscreenStatusState();
}

class _RecordingFullscreenStatusState extends State<RecordingFullscreenStatus> {
  late DateTime _now = _readClock();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _updatePolling();
  }

  @override
  void didUpdateWidget(covariant RecordingFullscreenStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.showClock != widget.showClock) {
      _updatePolling();
    }
  }

  DateTime _readClock() => widget.clock?.call() ?? DateTime.now();

  void _updatePolling() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active || !widget.showClock) return;
    _now = _readClock();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = _readClock();
      if (_now.minute != now.minute || _now.hour != now.hour) {
        setState(() => _now = now);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white, fontSize: 13);
    if (!widget.showClock) return const SizedBox.shrink();
    return Text(
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
        key: const ValueKey('recording-fullscreen-clock'),
        style: style);
  }
}
