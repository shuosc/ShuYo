import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/library_loan_item.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 借阅规则与读者证状态底部弹窗（实时从接口拉取，不写本地缓存）。
Future<void> showLibraryLoanRulesSheet(
  BuildContext context, {
  required LibraryApiClient apiClient,
  LibraryAuthService? authService,
  LibraryAuthSession? session,
  ValueChanged<LibraryAuthSession>? onSessionRefreshed,
  LibraryTodoCounts? initialLimit,
}) {
  final screenWidth = MediaQuery.sizeOf(context).width;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(maxWidth: math.min(560, screenWidth)),
    builder: (_) => _LibraryLoanRulesSheet(
      apiClient: apiClient,
      authService: authService,
      session: session,
      onSessionRefreshed: onSessionRefreshed,
      initialLimit: initialLimit,
    ),
  );
}

class _LibraryLoanRulesSheet extends StatefulWidget {
  const _LibraryLoanRulesSheet({
    required this.apiClient,
    this.authService,
    this.session,
    this.onSessionRefreshed,
    this.initialLimit,
  });

  final LibraryApiClient apiClient;
  final LibraryAuthService? authService;
  final LibraryAuthSession? session;
  final ValueChanged<LibraryAuthSession>? onSessionRefreshed;
  final LibraryTodoCounts? initialLimit;

  @override
  State<_LibraryLoanRulesSheet> createState() => _LibraryLoanRulesSheetState();
}

class _LibraryLoanRulesSheetState extends State<_LibraryLoanRulesSheet> {
  bool _loading = true;
  Object? _error;
  List<LibraryLoanRule> _rules = const [];
  LibraryReaderCardInfo? _cardInfo;
  late LibraryAuthSession? _session = widget.session;
  late LibraryTodoCounts? _todoCounts = widget.initialLimit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<T> _withAuthRetry<T>(
    Future<T> Function(LibraryAuthSession? session) action,
  ) async {
    try {
      return await action(_session);
    } on LibraryApiAuthRequiredException {
      if (widget.authService == null) rethrow;
      final refreshed = await widget.authService!.authorize(force: true);
      if (mounted) {
        _session = refreshed;
      }
      widget.onSessionRefreshed?.call(refreshed);
      return action(refreshed);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    List<LibraryLoanRule> rules = const [];
    LibraryReaderCardInfo? card;
    LibraryTodoCounts? limit = widget.initialLimit;
    Object? firstError;

    await Future.wait([
      _withAuthRetry((s) => widget.apiClient.fetchLoanRules(session: s))
          .then((v) => rules = v)
          .catchError((Object e) {
        firstError ??= e;
        return const <LibraryLoanRule>[];
      }),
      _withAuthRetry((s) => widget.apiClient.fetchReaderCardInfo(session: s))
          .then((v) => card = v)
          .catchError((Object _) => null),
      _withAuthRetry((s) => widget.apiClient.fetchUserLimit(session: s))
          .then((v) => limit = v)
          .catchError((Object _) => limit ?? const LibraryTodoCounts()),
    ]);

    if (!mounted) return;
    setState(() {
      _rules = rules;
      _cardInfo = card;
      _todoCounts = limit;
      _error = rules.isEmpty && card == null ? firstError : null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SafeArea(
      top: false,
      bottom: false,
      child: Container(
        key: const ValueKey('library-loan-rules-sheet'),
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
                    children: [
                      Expanded(
                        child: Text(
                          '借阅规则与读者证',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('library-loan-rules-close'),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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
                  24 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error is LibraryApiException
                                  ? (_error as LibraryApiException).message
                                  : '加载借阅规则失败，请稍后重试',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      if (_cardInfo != null) ...[
                        _sectionHeader(context, '读者证状态'),
                        _field(context, '姓名', _cardInfo!.name),
                        _field(context, '学院/单位', _cardInfo!.unit),
                        _field(context, '读者类型', _cardInfo!.userGroupName),
                        _field(
                          context,
                          '证件状态',
                          _cardInfo!.statusLabel,
                          valueColor: _cardInfo!.isNormal
                              ? colors.success
                              : colors.danger,
                        ),
                        if (_cardInfo!.startDate != null ||
                            _cardInfo!.endDate != null)
                          _field(
                            context,
                            '有效期',
                            '${_cardInfo!.startDate ?? '—'} 至 ${_cardInfo!.endDate ?? '—'}',
                          ),
                      ],
                      if (_todoCounts != null && _todoCounts!.hasAny) ...[
                        const SizedBox(height: 4),
                        _sectionHeader(context, '当前待办'),
                        if (_todoCounts!.expiredNum > 0)
                          _field(
                            context,
                            '逾期在借',
                            '${_todoCounts!.expiredNum} 本',
                            valueColor: colors.danger,
                          ),
                        if (_todoCounts!.requestNum > 0)
                          _field(
                              context, '预约请求', '${_todoCounts!.requestNum} 项'),
                        if (_todoCounts!.behaviorNum > 0)
                          _field(
                            context,
                            '待处理违章',
                            '${_todoCounts!.behaviorNum} 项',
                            valueColor: colors.warning,
                          ),
                      ],
                      if (_rules.isNotEmpty) ...[
                        if (_cardInfo != null ||
                            (_todoCounts != null && _todoCounts!.hasAny))
                          const SizedBox(height: 4),
                        for (final rule in _rules) ...[
                          _sectionHeader(context, rule.ruleName),
                          _field(
                            context,
                            '可借上限',
                            rule.maxBorrowingNumber == null
                                ? null
                                : '${rule.maxBorrowingNumber} 册',
                          ),
                          _field(
                            context,
                            '最多续借',
                            rule.maxRenewalTime == null
                                ? null
                                : '${rule.maxRenewalTime} 次',
                          ),
                          _field(context, '名义借期', rule.normalLoanPeriod),
                          _field(context, '最高罚金', rule.maxPenalty),
                          _field(context, '适用馆藏', rule.applicableLocation),
                        ],
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          decoration: BoxDecoration(
                            color: colors.surfaceAlt,
                            border: Border(
                              left: BorderSide(color: colors.accent, width: 3),
                            ),
                          ),
                          child: Text(
                            '名义借期仅供参考，实际每本书的应还日期可能因馆藏规则或假期顺延有所不同，请以在借列表的“应还日期”为准。',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      );

  Widget _field(
    BuildContext context,
    String label,
    String? value, {
    Color? valueColor,
  }) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: valueColor == null ? null : TextStyle(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
