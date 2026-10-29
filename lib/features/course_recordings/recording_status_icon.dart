import 'dart:math' as math;

import 'package:flutter/material.dart';

class RecordingStatusIcon extends StatefulWidget {
  const RecordingStatusIcon(
      {super.key,
      required this.isLive,
      this.enabled = true,
      this.disabledColor});

  final bool isLive;
  final bool enabled;
  final Color? disabledColor;

  @override
  State<RecordingStatusIcon> createState() => _RecordingStatusIconState();
}

class _RecordingStatusIconState extends State<RecordingStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(RecordingStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.isLive &&
        widget.enabled &&
        !MediaQuery.disableAnimationsOf(context)) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.enabled
        ? Theme.of(context).colorScheme.primary
        : widget.disabledColor ?? Theme.of(context).disabledColor;
    if (!widget.isLive) {
      return Icon(Icons.play_circle_outline_rounded,
          color: color, semanticLabel: '录播回放');
    }
    return Semantics(
      label: widget.enabled ? '正在直播' : '直播已结束',
      child: SizedBox(
        width: 24,
        height: 24,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var index = 0; index < 4; index++)
                Container(
                  width: 3,
                  height: 6 +
                      15 *
                          (.5 +
                              .5 *
                                  math.sin(_animation.value * math.pi * 2 +
                                      index * 1.7)),
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
