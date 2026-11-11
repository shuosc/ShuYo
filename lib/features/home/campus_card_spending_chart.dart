import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../data/models/campus_card.dart';
import '../../data/services/campus_card_service.dart'
    show CampusCardAuthRequiredException, CampusCardException;
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

/// A calendar day's spending and incoming funds, kept as separate totals.
class CampusCardDailySpending {
  const CampusCardDailySpending({
    required this.date,
    required this.amount,
    this.creditAmount = 0,
  });

  final DateTime date;
  final double amount;
  // The API has no transaction type: incoming funds may include refunds.
  final double creditAmount;
}

/// Returns [days] calendar days, oldest first, including all of [endDate].
/// The portal's date fields are school-local dates; no timezone conversion is
/// applied. UTC is used only for calendar arithmetic, avoiding DST boundaries.
List<CampusCardDailySpending> aggregateCampusCardDailySpending(
  Iterable<CampusCardBill> bills, {
  required DateTime endDate,
  required int days,
}) {
  if (days < 1) throw ArgumentError.value(days, 'days', 'Must be positive');
  final end = DateTime.utc(endDate.year, endDate.month, endDate.day);
  final start = end.subtract(Duration(days: days - 1));
  final amounts = List<double>.filled(days, 0);
  final credits = List<double>.filled(days, 0);
  for (final bill in bills) {
    if (!bill.amount.isFinite || bill.amount == 0) continue;
    final date = _billCalendarDate(bill.payTime);
    if (date == null || date.isBefore(start) || date.isAfter(end)) continue;
    final index = date.difference(start).inDays;
    if (bill.amount > 0) {
      amounts[index] += bill.amount;
    } else {
      credits[index] -= bill.amount;
    }
  }
  return List.unmodifiable(List.generate(days, (index) {
    final date = start.add(Duration(days: index));
    return CampusCardDailySpending(
      date: DateTime(date.year, date.month, date.day),
      amount: amounts[index],
      creditAmount: credits[index],
    );
  }));
}

final _billDatePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?(?:[zZ]|[+-]\d{2}(?::?\d{2})?)?)?$',
);

DateTime? _billCalendarDate(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), 'T');
  final match = _billDatePattern.firstMatch(normalized);
  if (match == null || DateTime.tryParse(normalized) == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  // DateTime.tryParse normalizes impossible days/times rather than rejecting
  // them, so validate the original calendar components as well.
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      (match[4] != null && int.parse(match[4]!) > 23) ||
      (match[5] != null && int.parse(match[5]!) > 59) ||
      (match[6] != null && int.parse(match[6]!) > 59)) {
    return null;
  }
  return date;
}

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// A local 7/30-day view over the parent's completed 30-day request.
/// A null list means no complete snapshot is available yet.
class CampusCardSpendingChart extends StatefulWidget {
  const CampusCardSpendingChart({
    super.key,
    required this.bills,
    required this.endDate,
    this.loading = false,
    this.error,
    this.onRetry,
  });

  final List<CampusCardBill>? bills;
  final DateTime endDate;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  @override
  State<CampusCardSpendingChart> createState() =>
      _CampusCardSpendingChartState();
}

class _CampusCardSpendingChartState extends State<CampusCardSpendingChart>
    with SingleTickerProviderStateMixin {
  int _days = 7;
  bool _showSelection = false;
  bool _dragging = false;
  late final AnimationController _selectionController;
  late final ValueNotifier<double> _selectionPosition;
  double _selectionFrom = 0;
  double _selectionTo = 0;
  // Start on the latest day, including a genuine zero-spending day.
  late DateTime _selectedDate = DateUtils.dateOnly(widget.endDate);
  List<CampusCardBill>? _cachedBills;
  DateTime? _cachedEndDate;
  int? _cachedDays;
  List<CampusCardDailySpending>? _cachedData;

  @override
  void initState() {
    super.initState();
    _selectionPosition = ValueNotifier(_days - 1.0);
    _selectionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(() {
        final progress =
            Curves.easeOutCubic.transform(_selectionController.value);
        _selectionPosition.value =
            _selectionFrom + (_selectionTo - _selectionFrom) * progress;
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) &&
        _selectionController.isAnimating) {
      _moveSelection(_selectedIndex.toDouble(), animate: false);
    }
  }

  @override
  void dispose() {
    _selectionController.dispose();
    _selectionPosition.dispose();
    super.dispose();
  }

  List<CampusCardDailySpending> get _data {
    if (_cachedData == null ||
        !identical(_cachedBills, widget.bills) ||
        !DateUtils.isSameDay(_cachedEndDate, widget.endDate) ||
        _cachedDays != _days) {
      _cachedBills = widget.bills;
      _cachedEndDate = widget.endDate;
      _cachedDays = _days;
      _cachedData = aggregateCampusCardDailySpending(
        widget.bills ?? const [],
        endDate: widget.endDate,
        days: _days,
      );
    }
    return _cachedData!;
  }

  @override
  void didUpdateWidget(covariant CampusCardSpendingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (DateUtils.isSameDay(_selectedDate, oldWidget.endDate)) {
      _selectedDate = DateUtils.dateOnly(widget.endDate);
    }
    _keepSelectionInRange();
    if (!DateUtils.isSameDay(oldWidget.endDate, widget.endDate) ||
        widget.bills == null) {
      _resetSelection();
    }
  }

  void _keepSelectionInRange() {
    final end =
        DateTime(widget.endDate.year, widget.endDate.month, widget.endDate.day);
    final start = DateTime(end.year, end.month, end.day - _days + 1);
    if (_selectedDate.isBefore(start) || _selectedDate.isAfter(end)) {
      _selectedDate = end;
    }
  }

  int get _selectedIndex {
    final data = _data;
    final selected =
        data.indexWhere((day) => DateUtils.isSameDay(day.date, _selectedDate));
    return selected < 0 ? data.length - 1 : selected;
  }

  void _moveSelection(double position, {bool animate = true}) {
    if (animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        (_selectionPosition.value - position).abs() > .001) {
      if (_selectionController.isAnimating && _selectionTo == position) return;
      // Retarget from the painted position, even when the previous tap's
      // animation has not finished yet.
      _selectionController.stop();
      _selectionFrom = _selectionPosition.value;
      _selectionTo = position;
      _selectionController.forward(from: 0);
    } else {
      _selectionController.stop();
      _selectionPosition.value = position;
    }
  }

  void _resetSelection() {
    _dragging = false;
    _moveSelection(_selectedIndex.toDouble(), animate: false);
  }

  void _select(DateTime date, {double? dragPosition}) {
    final index =
        _data.indexWhere((day) => DateUtils.isSameDay(day.date, date));
    if (index < 0) return;
    _dragging = dragPosition != null;
    _moveSelection(dragPosition ?? index.toDouble(), animate: !_dragging);
    if (_showSelection && DateUtils.isSameDay(date, _selectedDate)) return;
    setState(() {
      _selectedDate = date;
      _showSelection = true;
    });
  }

  void _dragTo(double position) =>
      _select(_data[position.round()].date, dragPosition: position);

  void _finishDrag() {
    if (!_dragging) return;
    _dragging = false;
    _moveSelection(_selectedIndex.toDouble());
  }

  Widget _legend(String label, Color color, {bool outlined = false}) => Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            Container(
                key: ValueKey('campus-card-chart-legend-$label'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: outlined ? null : color,
                    border: outlined ? Border.all(color: color) : null,
                    borderRadius: BorderRadius.circular(2))),
            Text(label,
                style: ShuYoTextStyles.meta(
                    color: context.shuyoColors.textSecondary)),
          ]);

  Widget _selectionInfo(
    CampusCardDailySpending day,
    ShuYoColors colors, {
    bool placeholder = false,
  }) {
    final style = ShuYoTextStyles.meta(color: colors.textSecondary).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget amount(String label, IconData icon, double value, String key) => Row(
          key: placeholder ? null : ValueKey('$key-row'),
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(icon, size: 14, color: colors.accent),
            const SizedBox(width: 4),
            Text(placeholder ? '$label\u200b' : label, style: style),
            const SizedBox(width: 4),
            Flexible(
              child: Text('¥ ${value.toStringAsFixed(2)}',
                  key: placeholder ? null : ValueKey(key),
                  style: style.copyWith(color: colors.accent)),
            ),
          ],
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          flex: 5,
          child: Text(placeholder ? '8888-88-88' : _dateKey(day.date),
              key: placeholder
                  ? null
                  : const ValueKey('campus-card-chart-selected-date'),
              textAlign: TextAlign.center,
              style: style),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              amount('充值', Icons.arrow_upward_rounded, day.creditAmount,
                  'campus-card-chart-selected-credit-amount'),
              const SizedBox(height: 4),
              amount('消费', Icons.arrow_downward_rounded, day.amount,
                  'campus-card-chart-selected-amount'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final error = widget.error;
    final mismatchedAccount =
        error is CampusCardException && error.code == 'accountMismatch';
    final requiresLogin =
        error is CampusCardAuthRequiredException || mismatchedAccount;
    final data = _data;
    final selectedIndex = _selectedIndex;
    return Column(
      key: const ValueKey('campus-card-spending-chart'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Semantics(
              header: true,
              child: Text('消费趋势',
                  style:
                      ShuYoTextStyles.sectionTitle(color: colors.textPrimary)),
            ),
            Wrap(spacing: 4, children: [
              for (final days in [7, 30])
                Semantics(
                  selected: _days == days,
                  child: TextButton(
                    key: ValueKey('campus-card-chart-range-$days'),
                    style: TextButton.styleFrom(
                      foregroundColor: _days == days
                          ? colors.onAccentSoft
                          : colors.textSecondary,
                      backgroundColor:
                          _days == days ? colors.accentSoft : colors.surface,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      textStyle: ShuYoTextStyles.label(),
                    ),
                    onPressed: () {
                      if (_days == days) return;
                      setState(() {
                        _days = days;
                        _keepSelectionInRange();
                        _showSelection = false;
                        _resetSelection();
                      });
                    },
                    child: Text('$days天'),
                  ),
                ),
            ]),
          ],
        ),
        const SizedBox(height: 10),
        if (error != null) ...[
          ConstrainedBox(
            key: const ValueKey('campus-card-chart-error'),
            constraints: BoxConstraints(
                minHeight: widget.bills == null || mismatchedAccount ? 184 : 0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: widget.bills == null || mismatchedAccount
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Text(requiresLogin ? '请登录校园账户' : '刷新失败',
                    style: ShuYoTextStyles.bodyCompact(
                        color: colors.textSecondary)),
                if (widget.onRetry != null)
                  TextButton(
                    key: const ValueKey('campus-card-chart-retry'),
                    onPressed: widget.onRetry,
                    style: TextButton.styleFrom(foregroundColor: colors.accent),
                    child: Text(requiresLogin ? '登录校园账户' : '重试'),
                  ),
              ],
            ),
          ),
        ],
        if (widget.bills == null && error == null)
          Semantics(
            liveRegion: true,
            child: ConstrainedBox(
              key: const ValueKey('campus-card-chart-loading'),
              constraints: const BoxConstraints(minHeight: 184),
              child: Center(
                  child: Text(widget.loading ? '正在加载消费趋势…' : '暂无消费趋势',
                      style: ShuYoTextStyles.bodyCompact(
                          color: colors.textSecondary))),
            ),
          )
        else if (widget.bills != null && !mismatchedAccount) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _legend('充值', colors.accent),
                  const SizedBox(height: 4),
                  _legend('消费', colors.accent, outlined: true),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.topRight,
                  child: IntrinsicWidth(
                      child: Stack(children: [
                    // Reserve enough room for every day in the current range so
                    // choosing or dragging between bars does not move the plot.
                    ExcludeSemantics(
                      child: Opacity(
                        opacity: 0,
                        child: _selectionInfo(
                          CampusCardDailySpending(
                            date: widget.endDate,
                            amount: data.fold<double>(
                                0, (max, day) => math.max(max, day.amount)),
                            creditAmount: data.fold<double>(0,
                                (max, day) => math.max(max, day.creditAmount)),
                          ),
                          colors,
                          placeholder: true,
                        ),
                      ),
                    ),
                    if (_showSelection)
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Semantics(
                            key: const ValueKey('campus-card-chart-selection'),
                            liveRegion: true,
                            label: '${_dateKey(data[selectedIndex].date)}，'
                                '充值 ¥ ${data[selectedIndex].creditAmount.toStringAsFixed(2)}，'
                                '消费 ¥ ${data[selectedIndex].amount.toStringAsFixed(2)}',
                            child: ExcludeSemantics(
                              child:
                                  _selectionInfo(data[selectedIndex], colors),
                            ),
                          ),
                        ),
                      ),
                  ])),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
              height: 150,
              child: LayoutBuilder(builder: (context, constraints) {
                final size = Size(constraints.maxWidth, 150);
                final painter = _SpendingBarPainter(
                  data: data,
                  selectedIndex: selectedIndex,
                  selectionPosition: _selectionPosition,
                  colors: colors,
                  labelStyle: ShuYoTextStyles.meta(
                          color: colors.textTertiary, size: 10.5)
                      .copyWith(
                          fontFamily: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.fontFamily),
                  textScaler: MediaQuery.textScalerOf(context),
                  onSelect: (index) => _select(data[index].date),
                );
                return Stack(fit: StackFit.expand, children: [
                  RepaintBoundary(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) => _select(
                          data[painter.indexAt(details.localPosition.dx, size)]
                              .date),
                      // A drag follows the finger continuously instead of
                      // restarting the tap animation at every date boundary.
                      onHorizontalDragStart: (details) => _dragTo(
                          painter.positionAt(details.localPosition.dx, size)),
                      onHorizontalDragUpdate: (details) => _dragTo(
                          painter.positionAt(details.localPosition.dx, size)),
                      onHorizontalDragEnd: (_) => _finishDrag(),
                      onHorizontalDragCancel: _finishDrag,
                      child: CustomPaint(
                        key: const ValueKey('campus-card-chart-plot'),
                        painter: painter,
                        size: size,
                      ),
                    ),
                  ),
                  if (data
                      .every((day) => day.amount == 0 && day.creditAmount == 0))
                    IgnorePointer(
                        child: Center(
                            child: Text(
                      '近$_days天暂无收支',
                      key: const ValueKey('campus-card-chart-empty'),
                      style: ShuYoTextStyles.meta(color: colors.textSecondary),
                    ))),
                ]);
              })),
        ],
      ],
    );
  }
}

class _SpendingBarPainter extends CustomPainter {
  _SpendingBarPainter(
      {required this.data,
      required this.selectedIndex,
      required this.selectionPosition,
      required this.colors,
      required this.labelStyle,
      required this.textScaler,
      required this.onSelect})
      : super(repaint: selectionPosition);

  final List<CampusCardDailySpending> data;
  final int selectedIndex;
  final ValueListenable<double> selectionPosition;
  final ShuYoColors colors;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final ValueChanged<int> onSelect;

  double get _ceiling {
    final max = data.fold<double>(
        0,
        (value, day) =>
            math.max(value, math.max(day.amount, day.creditAmount)));
    if (max <= 0) return 1;
    final unit = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
    final normalized = max / unit;
    return (normalized <= 1
            ? 1
            : normalized <= 2
                ? 2
                : normalized <= 5
                    ? 5
                    : 10) *
        unit;
  }

  String _axisLabel(double value) {
    if (value >= 10000) return '${_decimal(value / 10000)}万';
    if (value >= 1000) return '${_decimal(value / 1000)}千';
    return _decimal(value);
  }

  String _decimal(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(value < 1 ? 2 : 1);

  TextPainter _text(String label) => TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();

  Rect _plot(Size size) {
    final labels = [
      for (final value in [0.0, _ceiling / 2, _ceiling])
        _text(_axisLabel(value))
    ];
    final width =
        labels.fold<double>(0, (max, label) => math.max(max, label.width));
    final height =
        labels.fold<double>(0, (max, label) => math.max(max, label.height));
    final left = math.min(width + 8, math.max(0.0, size.width - 32));
    final top = math.min(height / 2 + 2, math.max(0.0, size.height - 24));
    return Rect.fromLTRB(left, top, math.max(left + 1, size.width - 6),
        math.max(top + 1, size.height - height - 10));
  }

  double positionAt(double dx, Size size) {
    final plot = _plot(size);
    return ((dx - plot.left) / plot.width * data.length - .5)
        .clamp(0.0, data.length - 1.0)
        .toDouble();
  }

  int indexAt(double dx, Size size) => positionAt(dx, size).round();

  double _dayX(num index, Rect plot) =>
      plot.left + plot.width * (index + .5) / data.length;

  @override
  void paint(Canvas canvas, Size size) {
    final ceiling = _ceiling;
    final plot = _plot(size);
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = plot.bottom - plot.height * fraction;
      canvas.drawLine(
          Offset(plot.left, y),
          Offset(plot.right, y),
          Paint()
            ..color = fraction == 0 ? colors.borderStrong : colors.border
            ..strokeWidth = 0.8);
      final label = _text(_axisLabel(ceiling * fraction));
      label.paint(
          canvas, Offset(plot.left - label.width - 8, y - label.height / 2));
    }
    final step = plot.width / data.length;
    final groupWidth = math.min(32.0, step * 0.78);
    final gap = math.min(3.0, groupWidth * 0.15);
    final barWidth = (groupWidth - gap) / 2;
    for (var index = 0; index < data.length; index++) {
      final left = _dayX(index, plot) - groupWidth / 2;
      // Blend adjacent days as the underline passes between their centers.
      final highlight =
          (1 - (index - selectionPosition.value).abs()).clamp(0.0, 1.0);
      for (var series = 0; series < 2; series++) {
        // Match the recharge-first order of the legend and selected amounts.
        final isCredit = series == 0;
        final amount = isCredit ? data[index].creditAmount : data[index].amount;
        if (amount == 0) continue;
        final height = plot.height * amount / ceiling;
        final rect = Rect.fromLTWH(left + series * (barWidth + gap),
            plot.bottom - height, barWidth, height);
        final color = colors.accent;
        final bar = RRect.fromRectAndCorners(rect,
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2));
        if (isCredit) {
          canvas.drawRRect(bar,
              Paint()..color = color.withValues(alpha: .55 + .45 * highlight));
        } else {
          // Keep the outline inside the original bar, even in the 30-day view.
          final strokeWidth = math.min(1.0, math.min(barWidth / 3, height / 3));
          final inset = strokeWidth / 2;
          if (rect.width > strokeWidth && rect.height > strokeWidth) {
            canvas.drawRRect(
                bar.deflate(inset),
                Paint()
                  ..color = color.withValues(alpha: .75 + .25 * highlight)
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = strokeWidth);
          }
        }
      }
    }
    // An underline selects the whole day, including days with two zero values.
    final selectedX = _dayX(selectionPosition.value, plot);
    canvas.drawLine(
        Offset(selectedX - groupWidth / 2, plot.bottom + 3),
        Offset(selectedX + groupWidth / 2, plot.bottom + 3),
        Paint()
          ..color = colors.textSecondary
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);

    Rect labelBounds(int index) {
      final day = data[index].date;
      final label = _text('${day.month}/${day.day}');
      final x = (_dayX(index, plot) - label.width / 2)
          .clamp(0.0, math.max(0.0, size.width - label.width))
          .toDouble();
      return Rect.fromLTWH(x, plot.bottom + 8, label.width, label.height);
    }

    final firstBounds = labelBounds(0);
    final lastBounds = labelBounds(data.length - 1);
    for (final index in [0, (data.length - 1) ~/ 2, data.length - 1]) {
      final bounds = labelBounds(index);
      if (index == 0 && firstBounds.right + 8 > lastBounds.left) continue;
      if (index != 0 &&
          index != data.length - 1 &&
          (bounds.left < firstBounds.right + 8 ||
              bounds.right > lastBounds.left - 8)) {
        continue;
      }
      final day = data[index].date;
      _text('${day.month}/${day.day}').paint(canvas, bounds.topLeft);
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
        final plot = _plot(size);
        final step = plot.width / data.length;
        return [
          for (var index = 0; index < data.length; index++)
            CustomPainterSemantics(
              key: ValueKey(
                  'campus-card-chart-day-${_dateKey(data[index].date)}'),
              rect: Rect.fromLTRB(
                plot.left + step * index,
                plot.top,
                plot.left + step * (index + 1),
                plot.bottom,
              ),
              properties: SemanticsProperties(
                textDirection: TextDirection.ltr,
                label:
                    '${_dateLabel(data[index].date)}，充值入账 ¥ ${data[index].creditAmount.toStringAsFixed(2)}，消费 ¥ ${data[index].amount.toStringAsFixed(2)}',
                button: true,
                selected: index == selectedIndex,
                onTap: () => onSelect(index),
              ),
            ),
        ];
      };

  @override
  bool shouldRepaint(covariant _SpendingBarPainter oldDelegate) =>
      data != oldDelegate.data ||
      selectedIndex != oldDelegate.selectedIndex ||
      selectionPosition != oldDelegate.selectionPosition ||
      colors != oldDelegate.colors ||
      labelStyle != oldDelegate.labelStyle ||
      textScaler != oldDelegate.textScaler;

  @override
  bool shouldRebuildSemantics(covariant _SpendingBarPainter oldDelegate) =>
      true;
}
