import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/time_format.dart';
import '../../shared/widgets/empty_state.dart';
import 'rate_navigation.dart';
import 'rate_widgets.dart';

/// Course review feedback, kept apart from the app feedback in settings.
class RateFeedbackListPage extends StatefulWidget {
  const RateFeedbackListPage({super.key, required this.repository});

  final CourseReviewRepository repository;

  @override
  State<RateFeedbackListPage> createState() => _RateFeedbackListPageState();
}

class _RateFeedbackListPageState extends State<RateFeedbackListPage> {
  List<RateFeedbackTicket>? _tickets;
  Object? _error;
  bool _needsIdentity = false;

  CourseReviewRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final tickets = await _repo.feedback();
      if (!mounted) return;
      setState(() {
        _tickets = tickets;
        _error = null;
        _needsIdentity = false;
      });
    } on CourseReviewIdentityRequired {
      if (mounted) setState(() => _needsIdentity = true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _compose() async {
    if (!await ensureRateIdentity(context, _repo) || !mounted) return;
    final sent = await Navigator.of(context).push<bool>(shuyoRoute(
        builder: (_) => RateFeedbackComposerPage(repository: _repo)));
    if (sent == true && mounted) await _load();
  }

  Future<void> _open(RateFeedbackTicket ticket) async {
    await Navigator.of(context).push<void>(shuyoRoute(
        builder: (_) =>
            RateFeedbackDetailPage(repository: _repo, ticket: ticket)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课评反馈')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _compose,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('提交反馈'),
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_needsIdentity) {
      return ListView(children: [
        EmptyState(
          icon: Icons.verified_user_outlined,
          title: '尚未完成身份认证',
          message: '认证后可以提交和查看课评反馈。',
          action: FilledButton(
            onPressed: () async {
              if (await ensureRateIdentity(context, _repo) && mounted) {
                await _load();
              }
            },
            child: const Text('去认证'),
          ),
        ),
      ]);
    }
    final tickets = _tickets;
    if (tickets == null) {
      return _error != null
          ? RateLoadError(error: _error, onRetry: _load)
          : const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (tickets.isEmpty) {
      return ListView(children: const [
        EmptyState(
          icon: Icons.chat_bubble_outline,
          title: '暂无课评反馈',
          message: '找不到课程、信息有误或有建议，都可以告诉我们。',
        ),
      ]);
    }
    final colors = context.shuyoColors;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        RateListCard(children: [
          for (final ticket in tickets)
            ListTile(
              onTap: () => _open(ticket),
              title: Text(ticket.kindLabel,
                  style: ShuYoTextStyles.title(
                      color: colors.textPrimary, size: 15.5)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ticket.targetText.isNotEmpty)
                      Text(ticket.targetText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ShuYoTextStyles.meta(
                              color: colors.textSecondary)),
                    Text(ticket.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            ShuYoTextStyles.meta(color: colors.textTertiary)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, children: [
                      _StatusTag(ticket: ticket),
                      RateTag(text: TimeFormat.compact(ticket.updatedAt)),
                      if (ticket.replies.isNotEmpty)
                        RateTag(text: '${ticket.replies.length} 回复'),
                    ]),
                  ],
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
            ),
        ]),
      ],
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.ticket});

  final RateFeedbackTicket ticket;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final color = switch (ticket.status) {
      'closed' => colors.textTertiary,
      'replied' => colors.success,
      _ => colors.warning,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(ticket.statusLabel,
          style: ShuYoTextStyles.meta(color: color, size: 11)),
    );
  }
}

class RateFeedbackComposerPage extends StatefulWidget {
  const RateFeedbackComposerPage({
    super.key,
    required this.repository,
    this.unit,
    this.course,
  });

  final CourseReviewRepository repository;
  final RateUnit? unit;
  final RateCourseRef? course;

  @override
  State<RateFeedbackComposerPage> createState() =>
      _RateFeedbackComposerPageState();
}

class _RateFeedbackComposerPageState extends State<RateFeedbackComposerPage> {
  late Future<RateCatalogConfig> _config = widget.repository.config();
  final _content = TextEditingController();
  late String _kind =
      widget.unit != null || widget.course != null ? 'incorrect' : '';
  bool _submitting = false;

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  String get _targetText {
    final unit = widget.unit;
    if (unit != null) {
      return '${unit.course.name}（${unit.course.id}）· ${unit.teacher.displayName}';
    }
    final course = widget.course;
    return course == null ? '' : '${course.name}（${course.id}）';
  }

  Future<void> _submit() async {
    final content = _content.text.trim();
    if (_kind.isEmpty) {
      showRateSnack(context, '请选择反馈类型');
      return;
    }
    if (content.isEmpty) {
      showRateSnack(context, '请填写反馈内容');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.repository.submitFeedback(
        kind: _kind,
        content: content,
        unitId: widget.unit?.id ?? '',
        courseId: widget.course?.id ?? '',
      );
      if (!mounted) return;
      showRateSnack(context, '反馈已提交，可在个人中心查看处理进度');
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showRateWriteError(context, widget.repository, error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('提交课评反馈')),
      body: FutureBuilder<RateCatalogConfig>(
        future: _config,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return RateLoadError(
                error: snapshot.error,
                onRetry: () =>
                    setState(() => _config = widget.repository.config()));
          }
          final kinds = snapshot.data!.feedbackKinds;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (_targetText.isNotEmpty) ...[
                Text('关联课程',
                    style: ShuYoTextStyles.meta(color: colors.textTertiary)),
                const SizedBox(height: 4),
                Text(_targetText,
                    style:
                        ShuYoTextStyles.bodyCompact(color: colors.textPrimary)),
                const SizedBox(height: 16),
              ],
              Text('反馈类型',
                  style: ShuYoTextStyles.meta(color: colors.textTertiary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kind in kinds)
                    ChoiceChip(
                      label: Text(kind.label),
                      selected: _kind == kind.key,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _kind = kind.key),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _content,
                minLines: 5,
                maxLines: 10,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: '内容',
                  hintText: '例如：这门课还有一位老师没有列出，工号或姓名是……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: Text(_submitting ? '提交中...' : '提交'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class RateFeedbackDetailPage extends StatefulWidget {
  const RateFeedbackDetailPage({
    super.key,
    required this.repository,
    required this.ticket,
  });

  final CourseReviewRepository repository;
  final RateFeedbackTicket ticket;

  @override
  State<RateFeedbackDetailPage> createState() => _RateFeedbackDetailPageState();
}

class _RateFeedbackDetailPageState extends State<RateFeedbackDetailPage> {
  late RateFeedbackTicket _ticket = widget.ticket;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final ticket = await widget.repository.feedbackDetail(_ticket.id);
      if (mounted) setState(() => _ticket = ticket);
    } on Object catch (error) {
      if (mounted) showRateSnack(context, '刷新失败：$error');
    }
  }

  Future<void> _close() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭反馈'),
        content: const Text('关闭后，这条反馈仍可查看，但不能重新打开。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final ticket = await widget.repository.closeFeedback(_ticket.id);
      if (mounted) setState(() => _ticket = ticket);
    } on Object catch (error) {
      if (mounted) showRateWriteError(context, widget.repository, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final ticket = _ticket;
    return Scaffold(
      appBar: AppBar(title: const Text('反馈详情')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            RateCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(ticket.kindLabel,
                          style: ShuYoTextStyles.title(
                              color: colors.textPrimary, size: 16)),
                    ),
                    _StatusTag(ticket: ticket),
                  ]),
                  if (ticket.targetText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(ticket.targetText,
                        style:
                            ShuYoTextStyles.meta(color: colors.textSecondary)),
                  ],
                  const SizedBox(height: 6),
                  Text('提交于 ${TimeFormat.compact(ticket.createdAt)}',
                      style: ShuYoTextStyles.meta(color: colors.textTertiary)),
                  const SizedBox(height: 12),
                  Text(ticket.content,
                      style: ShuYoTextStyles.bodyCompact(
                          color: colors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const RateSectionTitle(title: '回复'),
            if (ticket.replies.isEmpty)
              Text('暂无回复',
                  style: ShuYoTextStyles.meta(color: colors.textTertiary))
            else
              for (final reply in ticket.replies)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: RateCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ShuYo · ${TimeFormat.compact(reply.createdAt)}',
                            style: ShuYoTextStyles.meta(
                                color: colors.textTertiary)),
                        const SizedBox(height: 6),
                        Text(reply.message,
                            style: ShuYoTextStyles.bodyCompact(
                                color: colors.textSecondary)),
                      ],
                    ),
                  ),
                ),
            if (ticket.status != 'closed') ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _close,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('关闭这条反馈'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
