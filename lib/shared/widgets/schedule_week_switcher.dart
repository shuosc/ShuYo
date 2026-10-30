import 'package:flutter/material.dart';

import '../shuyo_text_styles.dart';
import '../theme/shuyo_theme.dart';

class ScheduleWeekSwitcher extends StatefulWidget {
  const ScheduleWeekSwitcher({
    super.key,
    required this.week,
    required this.maxWeek,
    required this.onPrevious,
    required this.onNext,
    required this.onQuickWeekSelected,
    this.enableQuickSwitch = true,
  });

  final int week;
  final int maxWeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<int> onQuickWeekSelected;
  final bool enableQuickSwitch;

  @override
  State<ScheduleWeekSwitcher> createState() => _ScheduleWeekSwitcherState();
}

class _ScheduleWeekSwitcherState extends State<ScheduleWeekSwitcher> {
  bool _fastSwitching = false;
  int _previewWeek = 1;
  double _dragStartDx = 0;
  int _dragStartWeek = 1;
  double _dragWidth = 1;
  double _scheduleAreaTop = 0;
  OverlayEntry? _previewOverlay;

  @override
  void initState() {
    super.initState();
    _previewWeek = widget.week.clamp(1, widget.maxWeek);
  }

  @override
  void didUpdateWidget(covariant ScheduleWeekSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_fastSwitching &&
        (oldWidget.week != widget.week ||
            oldWidget.maxWeek != widget.maxWeek)) {
      _previewWeek = widget.week.clamp(1, widget.maxWeek);
    } else if (_fastSwitching &&
        (oldWidget.maxWeek != widget.maxWeek || !widget.enableQuickSwitch)) {
      _previewWeek = _previewWeek.clamp(1, widget.maxWeek);
      _dragStartWeek = _dragStartWeek.clamp(1, widget.maxWeek);
      if (widget.maxWeek == 1 || !widget.enableQuickSwitch) {
        _fastSwitching = false;
      }
      final previewOverlay = _previewOverlay;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_previewOverlay, previewOverlay)) return;
        if (_fastSwitching) {
          previewOverlay?.markNeedsBuild();
        } else {
          _removePreviewOverlay();
        }
      });
    }
  }

  @override
  void dispose() {
    _removePreviewOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quickSwitchEnabled = widget.enableQuickSwitch && widget.maxWeek > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一周',
            onPressed: _fastSwitching ? null : widget.onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: quickSwitchEnabled
                      ? (details) => _beginFastSwitch(
                            details,
                            constraints.maxWidth,
                          )
                      : null,
                  onHorizontalDragUpdate:
                      quickSwitchEnabled ? _updateFastSwitch : null,
                  onHorizontalDragEnd:
                      quickSwitchEnabled ? _finishFastSwitch : null,
                  onHorizontalDragCancel:
                      quickSwitchEnabled ? _cancelFastSwitch : null,
                  child: SizedBox(
                    height: 48,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 120),
                        child: _fastSwitching
                            ? SizedBox(
                                key: const ValueKey('quick-week-scrubber'),
                                width: constraints.maxWidth.clamp(120.0, 190.0),
                                child: _WeekScrubber(
                                  week: _previewWeek,
                                  maxWeek: widget.maxWeek,
                                ),
                              )
                            : Text(
                                '第 ${widget.week} 周',
                                key: const ValueKey('week-title'),
                                textAlign: TextAlign.center,
                                style: ShuYoTextStyles.title(
                                  size: 16.5,
                                  weight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '下一周',
            onPressed: _fastSwitching ? null : widget.onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  void _beginFastSwitch(DragStartDetails details, double width) {
    setState(() {
      _fastSwitching = true;
      _previewWeek = widget.week.clamp(1, widget.maxWeek);
      _dragStartWeek = _previewWeek;
      _dragStartDx = details.localPosition.dx;
      _dragWidth = width;
    });
    _showPreviewOverlay();
  }

  void _updateFastSwitch(DragUpdateDetails details) {
    if (!_fastSwitching) return;
    final range = widget.maxWeek - 1;
    if (range <= 0) return;
    final pixelsPerWeek = (_dragWidth / (range * 2)).clamp(6.0, 18.0);
    final offset =
        ((details.localPosition.dx - _dragStartDx) / pixelsPerWeek).round();
    final week = (_dragStartWeek + offset).clamp(1, widget.maxWeek);
    if (week != _previewWeek) {
      setState(() => _previewWeek = week);
      _previewOverlay?.markNeedsBuild();
    }
  }

  void _finishFastSwitch(DragEndDetails details) {
    if (!_fastSwitching) return;
    final week = _previewWeek.clamp(1, widget.maxWeek);
    _removePreviewOverlay();
    setState(() => _fastSwitching = false);
    widget.onQuickWeekSelected(week);
  }

  void _cancelFastSwitch() {
    if (!_fastSwitching) return;
    _removePreviewOverlay();
    setState(() => _fastSwitching = false);
  }

  void _showPreviewOverlay() {
    _removePreviewOverlay();
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox) {
      _scheduleAreaTop =
          renderObject.localToGlobal(Offset(0, renderObject.size.height)).dy;
    }
    _previewOverlay = OverlayEntry(
      builder: (context) {
        final colors = context.shuyoColors;
        return Positioned(
          top: _scheduleAreaTop,
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 21, vertical: 9),
                  decoration: BoxDecoration(
                    color: colors.inverseSurface.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '第 $_previewWeek 周',
                    style: ShuYoTextStyles.meta(
                      color: colors.inverseOnSurface,
                      size: 16,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_previewOverlay!);
  }

  void _removePreviewOverlay() {
    _previewOverlay?.remove();
    _previewOverlay = null;
  }
}

class _WeekScrubber extends StatelessWidget {
  const _WeekScrubber({required this.week, required this.maxWeek});

  final int week;
  final int maxWeek;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final progress = maxWeek <= 1 ? 0.0 : (week - 1) / (maxWeek - 1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const dotSize = 14.0;
          final dotLeft = (constraints.maxWidth - dotSize) * progress;
          return SizedBox(
            height: dotSize,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.borderStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Positioned(
                  left: dotLeft,
                  child: Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: colors.background.withValues(alpha: 0.28),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
