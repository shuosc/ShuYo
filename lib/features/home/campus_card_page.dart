import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/campus_card.dart';
import '../../data/services/academic_account_store.dart';
import '../../data/services/campus_card_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'campus_card_date_range_sheet.dart';

// 来自企微工作台点击日志；businessid 是客户端内部应用 ID，与 OAuth agentid 不同。
// 通过已有校园一卡通应用进入，避免 sso/jump 对任意网页的域名限制。
const _rechargeAppUrl =
    'wxwork://jump?target=jump_to_third_app&businessid=5629500339709576';

// 启动失败时可复制的固定网页入口；金额、订单和支付仍由学校页面处理。
const _rechargeEntryUrl = 'https://pay.shu.edu.cn/epay/home/IndexLoginWXCorp';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({
    super.key,
    required this.onLogin,
    this.serviceFactory,
    this.fetchCardInfo,
    this.initialCard,
    this.initialQueriedAt,
    this.onCardUpdated,
    this.onAuthRequired,
  });

  final Future<bool> Function() onLogin;
  final CampusCardService Function()? serviceFactory;
  final Future<CampusCardInfo> Function()? fetchCardInfo;
  final CampusCardInfo? initialCard;
  final DateTime? initialQueriedAt;
  final void Function(CampusCardInfo, DateTime)? onCardUpdated;
  final Future<void> Function(CampusCardAuthRequiredException)? onAuthRequired;

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  CampusCardService? _ownedService;
  CampusCardService get _service =>
      widget.serviceFactory?.call() ?? (_ownedService ??= CampusCardService());
  late DateTimeRange _range;
  int? _presetDays = 7;
  late CampusCardInfo? _card = widget.initialCard;
  List<CampusCardBill>? _bills;
  Object? _cardError;
  Object? _billsError;
  late DateTime? _cardQueriedAt = widget.initialQueriedAt;
  bool _loadingCard = true;
  bool _loadingBills = true;
  bool _loggingIn = false;
  bool _refreshing = false;
  int _cardRevision = 0;
  bool _openingRecharge = false;
  int _billsRevision = 0;
  DateTimeRange? _billsRange;

  @override
  void initState() {
    super.initState();
    _range = _recentDays(7);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _ownedService?.dispose();
    super.dispose();
  }

  DateTimeRange _recentDays(int days) {
    final today = DateUtils.dateOnly(DateTime.now());
    return DateTimeRange(
      start: DateTime(today.year, today.month, today.day - days + 1),
      end: today,
    );
  }

  Object? get _refreshError {
    for (final error in [_cardError, _billsError]) {
      if (error is CampusCardAuthRequiredException && error.ssoExpired) {
        return error;
      }
    }
    return _cardError ?? _billsError;
  }

  Future<void> _refresh(
      {bool interactive = false, bool allowLogin = true}) async {
    if (_refreshing || _loggingIn) return;
    setState(() => _refreshing = true);
    try {
      await Future.wait([_loadCard(), _loadBills()]);
      if (!mounted) return;
      var error = _refreshError;
      if (error is CampusCardAuthRequiredException) {
        await widget.onAuthRequired?.call(error);
        if (!mounted) return;
        if (interactive && allowLogin && error.ssoExpired) {
          final loggedIn = await _login(refreshAfterLogin: false);
          if (!mounted) return;
          if (!loggedIn) {
            _showSnack(_errorMessage(error));
            return;
          }
          await Future.wait([_loadCard(), _loadBills()]);
          if (!mounted) return;
          error = _refreshError;
          if (error is CampusCardAuthRequiredException) {
            await widget.onAuthRequired?.call(error);
          }
        }
      }
      if (interactive && mounted) {
        final message = error == null
            ? '已刷新'
            : _cardError == null
                ? '余额已刷新，消费记录刷新失败：${_errorMessage(error)}'
                : _billsError == null
                    ? '消费记录已刷新，余额刷新失败：${_errorMessage(error)}'
                    : _errorMessage(error);
        _showSnack(message);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadCard() async {
    final revision = ++_cardRevision;
    setState(() {
      _loadingCard = true;
      _cardError = null;
    });
    try {
      final card =
          await (widget.fetchCardInfo?.call() ?? _service.fetchCardInfo());
      if (!mounted || revision != _cardRevision) return;
      final queriedAt = DateTime.now();
      setState(() {
        _card = card;
        _cardQueriedAt = queriedAt;
      });
      widget.onCardUpdated?.call(card, queriedAt);
    } on Object catch (error) {
      if (mounted && revision == _cardRevision) {
        setState(() => _cardError = error);
      }
    } finally {
      if (mounted && revision == _cardRevision) {
        setState(() => _loadingCard = false);
      }
    }
  }

  Future<void> _loadBills() async {
    final revision = ++_billsRevision;
    final range = _range;
    setState(() {
      _loadingBills = true;
      if (_billsRange != range) _bills = null;
      _billsError = null;
    });
    try {
      final bills = await _service.fetchBills(
        startDate: range.start,
        endDate: range.end,
      );
      if (!mounted || revision != _billsRevision) return;
      setState(() {
        _bills = bills;
        _billsRange = range;
      });
    } on Object catch (error) {
      if (mounted && revision == _billsRevision) {
        setState(() => _billsError = error);
      }
    } finally {
      if (mounted && revision == _billsRevision) {
        setState(() => _loadingBills = false);
      }
    }
  }

  Future<bool> _login({bool refreshAfterLogin = true}) async {
    if (_loggingIn) return false;
    setState(() => _loggingIn = true);
    var loggedIn = false;
    try {
      loggedIn = await widget.onLogin();
      if (loggedIn && mounted) {
        final studentId = await AcademicAccountStore().loadStudentId();
        if (!mounted) return false;
        if (_card?.studentId != studentId) {
          setState(() {
            _card = null;
            _cardQueriedAt = null;
            _bills = null;
            _billsRange = null;
          });
        }
      }
    } on Object {
      if (mounted) _showSnack('暂时无法完成登录，请稍后重试');
      loggedIn = false;
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
    if (loggedIn && mounted && refreshAfterLogin) {
      await _refresh(interactive: true, allowLogin: false);
    }
    return loggedIn;
  }

  Future<void> _openRecharge() async {
    if (_openingRecharge) return;
    setState(() => _openingRecharge = true);
    try {
      final opened = await launchUrl(
        Uri.parse(_rechargeAppUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _showRechargeLaunchError();
    } on Object {
      _showRechargeLaunchError();
    } finally {
      if (mounted) setState(() => _openingRecharge = false);
    }
  }

  void _showRechargeLaunchError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('无法打开企业微信，请确认已安装企业微信'),
        action: SnackBarAction(label: '复制入口', onPressed: _copyRechargeEntry),
      ),
    );
  }

  Future<void> _copyRechargeEntry() async {
    var message = '已复制充值入口，请在企业微信中打开';
    try {
      await Clipboard.setData(const ClipboardData(text: _rechargeEntryUrl));
    } on Object {
      message = '复制失败，请重试';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _selectRecentDays(int days) {
    setState(() {
      _presetDays = days;
      _range = _recentDays(days);
    });
    unawaited(_refreshBills());
  }

  Future<void> _selectRange() async {
    final range =
        await showCampusCardDateRangeSheet(context, initialRange: _range);
    if (range == null || !mounted) return;
    setState(() {
      _presetDays = null;
      _range = range;
    });
    await _refreshBills();
  }

  Future<void> _refreshBills() async {
    await _loadBills();
    if (!mounted) return;
    final error = _billsError;
    if (error is CampusCardAuthRequiredException) {
      await widget.onAuthRequired?.call(error);
      if (!mounted) return;
      if (error.ssoExpired) {
        final loggedIn = await _login();
        if (!loggedIn && mounted) _showSnack(_errorMessage(error));
        return;
      }
    }
    if (error != null && mounted) _showSnack(_errorMessage(error));
  }

  String _errorMessage(Object error) =>
      error is CampusCardAuthRequiredException && error.ssoExpired
          ? '登录已失效，请重新登录'
          : error is CampusCardException
              ? error.message
              : '查询失败，请检查网络后重试。';

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showDataInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('校园卡信息说明'),
        content: const Text('数据由学校信息门户提供，可能存在同步延迟。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('校园卡'),
            Transform.translate(
              offset: const Offset(-3, -0.5),
              child: Opacity(
                opacity: 0.65,
                child: IconButton(
                  tooltip: '校园卡信息说明',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.info_outline, size: 18),
                  onPressed: _showDataInfo,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新余额和消费记录',
            onPressed:
                _refreshing || _loadingCard || _loadingBills || _loggingIn
                    ? null
                    : () => _refresh(interactive: true),
            style: const ButtonStyle(
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStatePropertyAll(Colors.transparent),
            ),
            icon: _refreshing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: '正在刷新余额和消费记录',
                    ),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            if (!_loadingCard && !_loadingBills && !_loggingIn) {
              await _refresh(interactive: true);
            }
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                sliver: SliverList.list(children: [
                  _cardSection(),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      '消费记录',
                      style: ShuYoTextStyles.sectionTitle(
                          color: colors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _dateFilter(
                        label: '近 7 天',
                        selected: _presetDays == 7,
                        onPressed: () => _selectRecentDays(7),
                      ),
                      const SizedBox(width: 10),
                      _dateFilter(
                        label: '近 30 天',
                        selected: _presetDays == 30,
                        onPressed: () => _selectRecentDays(30),
                      ),
                      const SizedBox(width: 10),
                      _dateFilter(
                        label: '自选日期',
                        selected: _presetDays == null,
                        onPressed: _selectRange,
                      ),
                    ],
                  ),
                  if (_presetDays == null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${_date(_range.start)} 至 ${_date(_range.end)}',
                      style:
                          TextStyle(color: colors.textSecondary, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_bills != null)
                    Text(
                      '共 ${_bills!.length} 条',
                      style:
                          TextStyle(color: colors.textTertiary, fontSize: 12),
                    ),
                  if (_loadingBills && _bills == null)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          semanticsLabel: '正在查询消费记录',
                        ),
                      ),
                    )
                  else if (_billsError != null && _bills == null)
                    _errorSection(_billsError!,
                        onRetry: () => _refresh(interactive: true))
                  else if (_bills?.isEmpty == true)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        '所选日期内暂无消费记录，可切换日期查询。',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                ]),
              ),
              if (_bills != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  sliver: SliverList.builder(
                    itemCount: _bills!.length,
                    itemBuilder: (context, index) => _billRow(_bills![index]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateFilter({
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final colors = context.shuyoColors;
    return Expanded(
      child: Semantics(
        selected: selected,
        child: OutlinedButton(
          onPressed:
              _refreshing || _loadingBills || _loggingIn ? null : onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: selected ? colors.accent : colors.textSecondary,
            disabledForegroundColor:
                selected ? colors.accent : colors.textTertiary,
            backgroundColor: selected ? colors.accentSoft : Colors.transparent,
            disabledBackgroundColor:
                selected ? colors.accentSoft : Colors.transparent,
            side: BorderSide(color: selected ? colors.accent : colors.border),
            minimumSize: const Size.fromHeight(44),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            textStyle: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  Widget _cardSection() {
    final colors = context.shuyoColors;
    final card = _card;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    '校园卡余额',
                    style: ShuYoTextStyles.label(color: colors.textSecondary),
                  ),
                ),
                if (card != null)
                  Semantics(
                    label: '卡片状态：${card.status.isEmpty ? '未知' : card.status}',
                    excludeSemantics: true,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: card.status == '正常'
                            ? colors.accent
                            : const Color(0xFF555555),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingCard && card == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  semanticsLabel: '正在查询校园卡余额',
                ),
              ),
            )
          else if (_cardError != null && card == null)
            _errorSection(_cardError!,
                onRetry: () => _refresh(interactive: true))
          else if (card != null) ...[
            Semantics(
              label: '${card.balance.toStringAsFixed(2)} 元',
              excludeSemantics: true,
              child: Text(
                '¥ ${card.balance.toStringAsFixed(2)}',
                style: ShuYoTextStyles.title(
                  color: colors.textPrimary,
                  size: 36,
                  weight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (card.name.isNotEmpty)
                  Text(card.name,
                      style: ShuYoTextStyles.title(
                          color: colors.textPrimary,
                          size: 15,
                          weight: FontWeight.w600)),
                Text('学号 ${card.studentId}',
                    style: ShuYoTextStyles.meta(
                        color: colors.textSecondary, size: 13)),
              ],
            ),
            if (card.validUntil.isNotEmpty || _cardQueriedAt != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  if (card.validUntil.isNotEmpty)
                    _cardMetadata('有效期', card.validUntil),
                  if (_cardQueriedAt != null)
                    _cardMetadata('查询时间', _time(_cardQueriedAt!)),
                ],
              ),
            ],
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _openingRecharge ? null : _openRecharge,
              icon: const Icon(Icons.open_in_new),
              label: const Text('前往企业微信充值'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '打开校园一卡通后，点击「账户充值」。',
            style: ShuYoTextStyles.meta(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _cardMetadata(String label, String value) {
    final colors = context.shuyoColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ShuYoTextStyles.meta(color: colors.textTertiary)),
        const SizedBox(height: 4),
        Text(value, style: ShuYoTextStyles.meta(color: colors.textSecondary)),
      ],
    );
  }

  Widget _billRow(CampusCardBill bill) {
    final colors = context.shuyoColors;
    // 门户以扣款记正、入账记负；界面按余额变动方向展示。
    final balanceChange = -bill.amount;
    final sign = balanceChange > 0
        ? '+'
        : balanceChange < 0
            ? '-'
            : '';
    final amountText = '$sign¥ ${balanceChange.abs().toStringAsFixed(2)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 20,
              runSpacing: 8,
              children: [
                Text(bill.name,
                    style: ShuYoTextStyles.title(
                        color: colors.textPrimary,
                        size: 15,
                        weight: FontWeight.w500)),
                Text(amountText,
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(bill.payTime,
              style: TextStyle(color: colors.textTertiary, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _errorSection(Object error,
      {required Future<void> Function() onRetry}) {
    final authRequired = error is CampusCardAuthRequiredException ||
        error is CampusCardException && error.code == 'accountMismatch';
    final message = _errorMessage(error);
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: TextStyle(color: context.shuyoColors.textSecondary)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loggingIn || _refreshing
                ? null
                : authRequired
                    ? () => _login()
                    : onRetry,
            icon: Icon(authRequired ? Icons.login : Icons.refresh),
            label: Text(_loggingIn
                ? '正在登录…'
                : authRequired
                    ? '登录校园账户'
                    : '重试'),
          ),
        ],
      ),
    );
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
