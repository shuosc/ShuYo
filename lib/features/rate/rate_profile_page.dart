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
import 'rate_publish_page.dart';
import 'rate_widgets.dart';

class RateProfilePage extends StatefulWidget {
  const RateProfilePage({super.key, required this.repository});

  final CourseReviewRepository repository;

  @override
  State<RateProfilePage> createState() => _RateProfilePageState();
}

class _RateProfilePageState extends State<RateProfilePage> {
  RateMyReviews? _reviews;
  Object? _error;
  bool _needsIdentity = false;
  bool _loading = false;

  CourseReviewRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final reviews = await _repo.myReviews();
      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _error = null;
        _needsIdentity = false;
      });
    } on CourseReviewIdentityRequired {
      if (mounted) setState(() => _needsIdentity = true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    if (await ensureRateIdentity(context, _repo) && mounted) await _load();
  }

  Future<void> _edit(RateMyReviewItem item) async {
    final saved = await Navigator.of(context).push<bool>(shuyoRoute(
      builder: (_) => RateEditReviewPage(repository: _repo, unit: item.unit),
    ));
    if (saved == true && mounted) await _load();
  }

  Future<void> _delete(RateMyReviewItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条评价？'),
        content: Text(
            '「${item.unit.course.name} · ${item.unit.teacher.name}」的评价会被删除，统计会同步更新。删除后可以重新评价。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repo.deleteReview(item.unit.id);
      if (!mounted) return;
      showRateSnack(context, '评价已删除');
      await _load();
    } on Object catch (error) {
      if (mounted) showRateWriteError(context, _repo, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('个人中心')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            RateCard(
              padding: EdgeInsets.zero,
              onTap: () => openRateFeedbackList(context, _repo),
              child: ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('课评反馈'),
                subtitle: Text('课程或教师信息有误、找不到课程、功能建议',
                    style: ShuYoTextStyles.meta(color: colors.textTertiary)),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
            const SizedBox(height: 20),
            const RateSectionTitle(title: '我的评价'),
            ..._reviewSection(colors),
          ],
        ),
      ),
    );
  }

  List<Widget> _reviewSection(ShuYoColors colors) {
    if (_needsIdentity) {
      return [
        EmptyState(
          icon: Icons.verified_user_outlined,
          title: '尚未完成身份认证',
          message: '认证后可以查看和管理你发布的评价。',
          action: FilledButton(onPressed: _verify, child: const Text('去认证')),
        ),
      ];
    }
    final reviews = _reviews;
    if (reviews == null) {
      if (_error != null) return [RateLoadError(error: _error, onRetry: _load)];
      return const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
        ),
      ];
    }
    return [
      if (reviews.blocked)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('该账户暂无法发布评价，如有疑问请通过课评反馈联系我们。',
              style: ShuYoTextStyles.meta(color: colors.danger)),
        ),
      if (reviews.reviews.isEmpty)
        const EmptyState(
          icon: Icons.rate_review_outlined,
          title: '还没有评价',
          message: '在课程详情页点击「发布评价」即可评价。',
        )
      else
        RateListCard(children: [
          for (final item in reviews.reviews)
            _ReviewTile(
              item: item,
              onOpen: () => openRateUnit(context, _repo, item.unit.id),
              onEdit: () => _edit(item),
              onDelete: () => _delete(item),
            ),
        ]),
    ];
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({
    required this.item,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final RateMyReviewItem item;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.unit.course.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ShuYoTextStyles.title(
                          color: colors.textPrimary, size: 15.5)),
                  const SizedBox(height: 3),
                  Text(
                    '${item.unit.teacher.displayName} · ${item.unit.course.id}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.meta(color: colors.textTertiary),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      RateStars(average: item.overall + 5.0, size: 13),
                      Text(TimeFormat.compact(item.updatedAt),
                          style: ShuYoTextStyles.meta(
                              color: colors.textTertiary, size: 11.5)),
                      if (!item.hasGrading) const RateTag(text: '未填给分倾向'),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) => switch (value) {
                'open' => onOpen(),
                'edit' => onEdit(),
                _ => onDelete(),
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'open', child: Text('查看课程评价')),
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
