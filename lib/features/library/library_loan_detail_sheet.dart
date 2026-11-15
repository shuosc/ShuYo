import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/library_loan_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_book_detail_page.dart';
import 'library_loan_list_tile.dart';

typedef LibraryLoanRenewResult = ({LibraryLoanItem? loan, String? message});

/// 借阅记录详情底部弹窗。
///
/// 融合学业课程详情（左侧竖条标题强调、左侧描边提示条、96px 标签键值对）
/// 与图书馆座位预约详情（拖拽条、8px 状态点、底部固定操作按钮、二次确认弹窗）规范。
Future<void> showLibraryLoanDetailSheet(
  BuildContext context, {
  required LibraryLoanItem loan,
  required LibraryApiClient apiClient,
  LibraryAuthSession? session,
  Future<LibraryLoanRenewResult> Function(LibraryLoanItem loan)? onRenew,
  DateTime? now,
}) {
  final screenWidth = MediaQuery.sizeOf(context).width;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(maxWidth: math.min(560, screenWidth)),
    builder: (sheetContext) => _LibraryLoanDetailSheet(
      initialLoan: loan,
      apiClient: apiClient,
      session: session,
      onRenew: onRenew,
      now: now,
    ),
  );
}

class _LibraryLoanDetailSheet extends StatefulWidget {
  const _LibraryLoanDetailSheet({
    required this.initialLoan,
    required this.apiClient,
    this.session,
    this.onRenew,
    this.now,
  });

  final LibraryLoanItem initialLoan;
  final LibraryApiClient apiClient;
  final LibraryAuthSession? session;
  final Future<LibraryLoanRenewResult> Function(LibraryLoanItem loan)? onRenew;
  final DateTime? now;

  @override
  State<_LibraryLoanDetailSheet> createState() =>
      _LibraryLoanDetailSheetState();
}

class _LibraryLoanDetailSheetState extends State<_LibraryLoanDetailSheet> {
  late LibraryLoanItem _loan = widget.initialLoan;
  bool _renewing = false;
  String? _renewError;
  String? _statusFeedback;
  String? _copiedLabel;
  Timer? _feedbackTimer;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  int? _borrowedDays() {
    final start = _loan.loanDate;
    if (start == null) return null;
    final end = _loan.isHistory
        ? _loan.returnDate
        : DateUtils.dateOnly((widget.now ?? DateTime.now()).toLocal());
    if (end == null) return null;
    final days = DateTime.utc(end.year, end.month, end.day)
        .difference(DateTime.utc(start.year, start.month, start.day))
        .inDays;
    return days >= 0 ? days : null;
  }

  Future<void> _copyValue(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() {
      _copiedLabel = label;
      _statusFeedback = '已复制$label：$value';
    });
    _feedbackTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        if (_copiedLabel == label) _copiedLabel = null;
      });
    });
  }

  Future<void> _confirmAndRenew() async {
    if (_renewing) return;
    final loan = _loan;
    if (!loan.canRenewAt(now: widget.now)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认续借'),
        content: Text(
          '确认续借《${loan.title}》？\n'
          '当前应还日期为 ${loan.dueDateText ?? '—'}，本次续借后剩余可续次数将变为 ${(loan.surplusRenewTimes - 1).clamp(0, 99)} 次。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认续借'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _renewing = true;
      _renewError = null;
      _statusFeedback = null;
    });
    try {
      final result = await widget.onRenew?.call(loan);
      if (!mounted) return;
      final updated = result?.loan;
      setState(() {
        _loan = updated ??
            _loan.copyWith(
              renewTimes: _loan.renewTimes + 1,
              surplusRenewTimes: (_loan.surplusRenewTimes - 1).clamp(0, 99),
            );
        _statusFeedback = result?.message ?? '续借成功';
      });
    } on Object catch (error) {
      if (!mounted) return;
      final message =
          error is LibraryApiException ? error.message : '续借失败，请稍后重试';
      setState(() => _renewError = message);
    } finally {
      if (mounted) {
        setState(() => _renewing = false);
      }
    }
  }

  void _openBookDetail() {
    final recordId = _loan.recordId;
    if (recordId == null || recordId <= 0) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      shuyoRoute(
        builder: (_) => LibraryBookDetailPage(
          recordId: recordId,
          title: _loan.title,
          author: _loan.author,
          publisher: _loan.publisher,
          publishYear: _loan.publishYear,
          apiClient: widget.apiClient,
          session: widget.session,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final status = _loan.statusAt(now: widget.now);
    final statusLabel = _loan.statusLabel(now: widget.now);
    final visual = libraryLoanStatusVisual(status, colors);
    final borrowedDays = _borrowedDays();
    final publisherText = [
      if (_loan.publisher != null) _loan.publisher!,
      if (_loan.publishYear != null) _loan.publishYear!,
    ].join(' · ');
    final location = _loan.locationName;
    final currentLocation = _loan.currentLocation;
    final showCurrentLocation = currentLocation != null &&
        currentLocation != location &&
        currentLocation.isNotEmpty;
    final disableReason = _loan.renewDisabledReason(now: widget.now);
    final canRenew = !_loan.isHistory &&
        widget.onRenew != null &&
        _loan.canRenewAt(now: widget.now) &&
        ((_loan.barcode?.isNotEmpty ?? false) || _loan.loanId != null);
    final hasBookDetail = _loan.recordId != null && _loan.recordId! > 0;
    final showActionBar =
        hasBookDetail || (!_loan.isHistory && widget.onRenew != null);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        key: const ValueKey('library-loan-detail-sheet'),
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.borderStrong,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 4,
                        height: 24,
                        decoration: BoxDecoration(
                          color: visual.color,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _loan.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('library-loan-detail-close'),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: visual.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          statusLabel,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: visual.color,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        if (borrowedDays != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            _loan.isHistory
                                ? '借期 $borrowedDays 天'
                                : '已借 $borrowedDays 天',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colors.textSecondary,
                                    ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Divider(height: 1, color: colors.border),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  12,
                  24,
                  showActionBar ? 12 : 24 + bottomInset,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailRow(context, '著者', _loan.author),
                    _detailRow(
                      context,
                      '出版信息',
                      publisherText.isEmpty ? null : publisherText,
                    ),
                    _detailRow(context, '馆藏地点', location),
                    if (showCurrentLocation)
                      _detailRow(context, '当前位置', currentLocation),
                    _detailRow(
                      context,
                      '索书号',
                      _loan.callNo,
                      copyLabel: '索书号',
                    ),
                    _detailRow(
                      context,
                      '册条码',
                      _loan.barcode,
                      copyLabel: '册条码',
                    ),
                    _detailRow(context, '借出日期', _loan.loanDateText),
                    _detailRow(context, '应还日期', _loan.dueDateText),
                    _detailRow(context, '实还日期', _loan.returnDateText),
                    if (!_loan.isHistory) ...[
                      _detailRow(
                        context,
                        '续借情况',
                        '已续 ${_loan.renewTimes} 次 · 剩余 ${_loan.surplusRenewTimes} 次',
                      ),
                      _detailRow(
                        context,
                        '预约状态',
                        _loan.isRequested ? '已被他人预约' : '当前无人预约',
                      ),
                    ] else if (_loan.renewTimes > 0)
                      _detailRow(context, '续借次数', '共续借 ${_loan.renewTimes} 次'),
                    if (_statusFeedback != null) ...[
                      const SizedBox(height: 4),
                      Semantics(
                        liveRegion: true,
                        child: _calloutBanner(
                          context,
                          text: _statusFeedback!,
                          accentColor: colors.success,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_renewError != null) ...[
                      const SizedBox(height: 4),
                      Semantics(
                        liveRegion: true,
                        child: _calloutBanner(
                          context,
                          text: _renewError!,
                          accentColor: colors.danger,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else if (disableReason != null && !_loan.isHistory) ...[
                      const SizedBox(height: 4),
                      _calloutBanner(
                        context,
                        text: disableReason,
                        accentColor: status == LibraryLoanStatus.overdue
                            ? colors.danger
                            : colors.textTertiary,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_loan.isOnlineReturn && !_loan.isHistory) ...[
                      _calloutBanner(
                        context,
                        text: '该图书支持线上还书流程。',
                        accentColor: colors.accent,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            if (showActionBar)
              Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottomInset),
                child: Row(
                  children: [
                    if (hasBookDetail)
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('library-loan-detail-book'),
                          onPressed: _openBookDetail,
                          icon: const Icon(Icons.menu_book_outlined),
                          label: const Text('图书详情'),
                        ),
                      ),
                    if (hasBookDetail &&
                        !_loan.isHistory &&
                        widget.onRenew != null)
                      const SizedBox(width: 12),
                    if (!_loan.isHistory && widget.onRenew != null)
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('library-loan-detail-renew'),
                          onPressed:
                              canRenew && !_renewing ? _confirmAndRenew : null,
                          icon: _renewing
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.onAccent,
                                  ),
                                )
                              : const Icon(Icons.autorenew),
                          label: Text(_renewing ? '正在续借…' : '续借'),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(
    BuildContext context,
    String label,
    String? value, {
    String? copyLabel,
  }) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    final colors = context.shuyoColors;
    final isCopied = copyLabel != null && _copiedLabel == copyLabel;
    return Padding(
      padding: EdgeInsets.only(bottom: copyLabel == null ? 12 : 4),
      child: Row(
        crossAxisAlignment: copyLabel == null
            ? CrossAxisAlignment.baseline
            : CrossAxisAlignment.center,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
            ),
          ),
          Expanded(
            child: copyLabel == null
                ? Text(value)
                : Row(
                    children: [
                      Expanded(child: Text(value)),
                      IconButton(
                        key: ValueKey('library-loan-copy-$copyLabel'),
                        tooltip: '复制$copyLabel',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        icon: Icon(
                          isCopied ? Icons.check_rounded : Icons.copy_outlined,
                          size: 16,
                          color:
                              isCopied ? colors.success : colors.textSecondary,
                        ),
                        onPressed: () => _copyValue(copyLabel, value),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _calloutBanner(
    BuildContext context, {
    required String text,
    required Color accentColor,
  }) {
    final colors = context.shuyoColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(left: BorderSide(color: accentColor, width: 3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 13,
          height: 1.45,
        ),
      ),
    );
  }
}
