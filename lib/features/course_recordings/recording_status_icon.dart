import 'dart:math' as math;

import 'package:flutter/material.dart';

class RecordingStatusIcon extends StatefulWidget {
  const RecordingStatusIcon(
      {super.key,
      required this.isLive,
      this.isGenerating = false,
      this.enabled = true,
      this.disabledColor,
      this.backgroundColor});

  final bool isLive;
  final bool isGenerating;
  final bool enabled;
  final Color? disabledColor;
  final Color? backgroundColor;

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
    if ((widget.isGenerating || widget.isLive && widget.enabled) &&
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
      return Semantics(
        label: widget.isGenerating ? '回放生成中' : '录播回放',
        excludeSemantics: true,
        child: SizedBox(
          width: 24,
          height: 24,
          child: Stack(clipBehavior: Clip.none, children: [
            Icon(Icons.smart_display_rounded, color: color),
            if (widget.isGenerating)
              Positioned(
                right: -1,
                bottom: -1,
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: AnimatedBuilder(
                    animation: _animation,
                    child: CustomPaint(
                      key: const ValueKey('recording-generating-indicator'),
                      painter: _GenerationIndicator(
                        color: color,
                        background: widget.backgroundColor ??
                            Theme.of(context).colorScheme.surface,
                      ),
                    ),
                    builder: (context, child) => Transform.rotate(
                        angle: _animation.value * math.pi * 2, child: child),
                  ),
                ),
              ),
          ]),
        ),
      );
    }
    return Semantics(
      label: widget.enabled ? '正在直播' : '直播已结束',
      child: RepaintBoundary(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CustomPaint(
            key: const ValueKey('recording-live-indicator'),
            painter: _LiveIndicator(color: color, animation: _animation),
          ),
        ),
      ),
    );
  }
}

// Repaint the small icon directly instead of rebuilding and laying out four
// changing containers on every animation frame while the list is scrolling.
class _LiveIndicator extends CustomPainter {
  _LiveIndicator({required this.color, required this.animation})
      : super(repaint: animation);

  final Color color;
  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    const barWidth = 3.0;
    final spacing = (size.width - barWidth * 4) / 5;
    final paint = Paint()..color = color;
    for (var index = 0; index < 4; index++) {
      final height = 6 +
          15 *
              (.5 + .5 * math.sin(animation.value * math.pi * 2 + index * 1.7));
      final rect = Rect.fromLTWH(spacing * (index + 1) + barWidth * index,
          (size.height - height) / 2, barWidth, height);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)), paint);
    }
  }

  @override
  bool shouldRepaint(_LiveIndicator oldDelegate) =>
      color != oldDelegate.color || animation != oldDelegate.animation;
}

class _GenerationIndicator extends CustomPainter {
  const _GenerationIndicator({required this.color, required this.background});

  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = background);
    final bounds = Rect.fromCircle(center: center, radius: radius - 2);
    canvas.drawArc(
        bounds,
        -math.pi / 2,
        math.pi * 1.5,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_GenerationIndicator oldDelegate) =>
      color != oldDelegate.color || background != oldDelegate.background;
}
