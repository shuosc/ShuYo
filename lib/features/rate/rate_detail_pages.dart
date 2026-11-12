import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'rate_navigation.dart';
import 'rate_widgets.dart';

class RateCoursePage extends StatefulWidget {
  const RateCoursePage({
    super.key,
    required this.repository,
    required this.courseId,
    this.highlightedUnitIds = const [],
  });

  final CourseReviewRepository repository;
  final String courseId;

  /// Teachers of the user's own teaching class, listed first.
  final List<String> highlightedUnitIds;

  @override
  State<RateCoursePage> createState() => _RateCoursePageState();
}

class _RateCoursePageState extends State<RateCoursePage> {
  late Future<RateCourseDetail> _future = _load();

  Future<RateCourseDetail> _load() => widget.repository.course(widget.courseId);

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('课程')),
      body: FutureBuilder<RateCourseDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return RateLoadError(
                error: snapshot.error,
                onRetry: () => setState(() => _future = _load()));
          }
          final detail = snapshot.data!;
          final mine = widget.highlightedUnitIds.toSet();
          final units = [
            ...detail.units.where((unit) => mine.contains(unit.id)),
            ...detail.units.where((unit) => !mine.contains(unit.id)),
          ];
          return RefreshIndicator(
            onRefresh: () async {
              final next = _load();
              setState(() => _future = next);
              await next;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(detail.course.name,
                    style: ShuYoTextStyles.title(
                        color: colors.textPrimary,
                        size: 17,
                        weight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(detail.course.metaText,
                    style: ShuYoTextStyles.meta(color: colors.textTertiary)),
                const SizedBox(height: 16),
                RateSectionTitle(title: '授课教师（${units.length}）'),
                RateListCard(children: [
                  for (final unit in units)
                    RateListTile(
                      title: unit.teacher.displayName,
                      subtitle: unit.teacher.title,
                      badge: mine.contains(unit.id) ? '你的老师' : null,
                      average: unit.average,
                      count: unit.reviewCount,
                      onTap: () =>
                          openRateUnit(context, widget.repository, unit.id),
                    ),
                ]),
                const SizedBox(height: 12),
                RateFeedbackLink(
                  onTap: () => openRateFeedbackComposer(
                      context, widget.repository,
                      course: detail.course),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class RateTeacherPage extends StatefulWidget {
  const RateTeacherPage({
    super.key,
    required this.repository,
    required this.teacherId,
  });

  final CourseReviewRepository repository;
  final String teacherId;

  @override
  State<RateTeacherPage> createState() => _RateTeacherPageState();
}

class _RateTeacherPageState extends State<RateTeacherPage> {
  late Future<RateTeacherDetail> _future = _load();

  Future<RateTeacherDetail> _load() =>
      widget.repository.teacher(widget.teacherId);

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('教师')),
      body: FutureBuilder<RateTeacherDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return RateLoadError(
                error: snapshot.error,
                onRetry: () => setState(() => _future = _load()));
          }
          final detail = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(detail.teacher.name,
                  style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 20,
                      weight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(
                [detail.teacher.college, detail.teacher.title]
                    .where((part) => part.isNotEmpty)
                    .join(' · '),
                style: ShuYoTextStyles.meta(color: colors.textTertiary),
              ),
              const SizedBox(height: 16),
              RateSectionTitle(title: '所授课程（${detail.units.length}）'),
              RateListCard(children: [
                for (final unit in detail.units)
                  RateListTile(
                    title: unit.course.name,
                    subtitle: unit.course.metaText,
                    average: unit.average,
                    count: unit.reviewCount,
                    onTap: () =>
                        openRateUnit(context, widget.repository, unit.id),
                  ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

class RateUnitPage extends StatefulWidget {
  const RateUnitPage({
    super.key,
    required this.repository,
    required this.unitId,
  });

  final CourseReviewRepository repository;
  final String unitId;

  @override
  State<RateUnitPage> createState() => _RateUnitPageState();
}

class _RateUnitPageState extends State<RateUnitPage> {
  RateUnitDetail? _detail;
  RateMyReview? _mine;
  Object? _error;
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
    final mine = _repo
        .myReview(widget.unitId)
        .then<RateMyReview?>((value) => value, onError: (Object _) => null);
    try {
      final detail = await _repo.unit(widget.unitId);
      final review = await mine;
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _mine = review;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publish() async {
    final detail = _detail;
    if (detail == null) return;
    final saved =
        await openRatePublish(context, _repo, detail.unit, existing: _mine);
    if (saved && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('课程评价')),
      body: detail == null
          ? (_error != null
              ? RateLoadError(error: _error, onRetry: _load)
              : const Center(child: CircularProgressIndicator(strokeWidth: 3)))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _UnitHeader(
                    unit: detail.unit,
                    onOpenCourse: () =>
                        openRateCourse(context, _repo, detail.unit.course.id),
                    onOpenTeacher: () =>
                        openRateTeacher(context, _repo, detail.unit.teacher.id),
                  ),
                  if (detail.unit.reviewCount > 0)
                    for (final stat in detail.stats)
                      if (stat.key != RateQuestion.overallKey) ...[
                        const SizedBox(height: 12),
                        _QuestionStatCard(stat: stat),
                      ],
                  const SizedBox(height: 12),
                  RateFeedbackLink(
                    onTap: () => openRateFeedbackComposer(context, _repo,
                        unit: detail.unit),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: detail == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton(
                onPressed: _loading ? null : _publish,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: Text(_mine == null ? '发布评价' : '修改我的评价'),
              ),
            ),
    );
  }
}

class _UnitHeader extends StatelessWidget {
  const _UnitHeader({
    required this.unit,
    required this.onOpenCourse,
    required this.onOpenTeacher,
  });

  final RateUnit unit;
  final VoidCallback onOpenCourse;
  final VoidCallback onOpenTeacher;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return RateCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpenCourse,
            child: Text(unit.course.name,
                style: ShuYoTextStyles.body(
                    color: colors.textPrimary, size: 15.5)),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: onOpenTeacher,
            child: Row(
              children: [
                Flexible(
                  child: Text(unit.teacher.displayName,
                      style: ShuYoTextStyles.title(
                          color: colors.textPrimary,
                          size: 20,
                          weight: FontWeight.w500)),
                ),
                Icon(Icons.chevron_right, size: 18, color: colors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (unit.average == null)
            Text('暂无评价',
                style: ShuYoTextStyles.title(
                    color: colors.textTertiary,
                    size: 17,
                    weight: FontWeight.w400))
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(rateScoreText(unit.average),
                    style: ShuYoTextStyles.title(
                        color: colors.textPrimary,
                        size: 32,
                        height: 1.1,
                        weight: FontWeight.w500)),
                const SizedBox(width: 4),
                Text('/ 10',
                    style: ShuYoTextStyles.body(
                        color: colors.textTertiary, size: 14.5)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                RateStars(average: unit.average, size: 16),
                const SizedBox(width: 8),
                Text('${unit.reviewCount} 份评价',
                    style: ShuYoTextStyles.meta(color: colors.textSecondary)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(unit.course.metaText,
              style: ShuYoTextStyles.meta(color: colors.textTertiary)),
        ],
      ),
    );
  }
}

class _QuestionStatCard extends StatelessWidget {
  const _QuestionStatCard({required this.stat});

  final RateQuestionStat stat;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return RateCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(stat.title,
                  style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 14.5,
                      weight: FontWeight.w500)),
              if (stat.multiple) ...[
                const SizedBox(width: 6),
                const RateTag(text: '可多选'),
              ],
              const Spacer(),
              Text('${stat.answered} 人回答',
                  style: ShuYoTextStyles.meta(color: colors.textTertiary)),
            ],
          ),
          const SizedBox(height: 10),
          if (stat.answered == 0)
            Text('暂时没有人回答这一题',
                style: ShuYoTextStyles.meta(color: colors.textTertiary))
          else
            for (final option in stat.options) _OptionStatRow(option: option),
        ],
      ),
    );
  }
}

/// Highlighting changes only color and weight, never the row size.
class _OptionStatRow extends StatelessWidget {
  const _OptionStatRow({required this.option});

  final RateOptionStat option;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final top = option.top;
    final textColor = top ? colors.accent : colors.textSecondary;
    final weight = top ? FontWeight.w500 : FontWeight.w400;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(option.label,
                    style: ShuYoTextStyles.bodyCompact(
                        color: textColor, size: 13.5, weight: weight)),
              ),
              Text('${option.percent}%',
                  style:
                      ShuYoTextStyles.meta(color: textColor, weight: weight)),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 3,
              child: Stack(
                children: [
                  Positioned.fill(
                      child: ColoredBox(color: colors.surfaceMuted)),
                  FractionallySizedBox(
                    widthFactor: (option.percent / 100).clamp(0, 1).toDouble(),
                    child: ColoredBox(
                        color: top ? colors.accent : colors.borderStrong),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
