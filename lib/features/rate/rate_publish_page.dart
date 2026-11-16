import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'rate_navigation.dart';
import 'rate_question_widgets.dart';
import 'rate_widgets.dart';

/// One question per page, then a summary page. Pops true once saved.
class RatePublishPage extends StatefulWidget {
  const RatePublishPage({
    super.key,
    required this.repository,
    required this.unit,
    this.existing,
  });

  final CourseReviewRepository repository;
  final RateUnit unit;
  final RateMyReview? existing;

  @override
  State<RatePublishPage> createState() => _RatePublishPageState();
}

class _RatePublishPageState extends State<RatePublishPage> {
  late Future<RateCatalogConfig> _config =
      widget.repository.config(forceRefresh: true);
  late int _overall = widget.existing?.overall ?? 0;
  late final Map<String, List<String>> _answers = {
    for (final entry in (widget.existing?.answers ?? const {}).entries)
      entry.key: [...entry.value],
  };
  int _index = 0;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RateCatalogConfig>(
      future: _config,
      builder: (context, snapshot) {
        final questions = snapshot.data?.questions ?? const <RateQuestion>[];
        final ready = snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            questions.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.existing == null ? '发布评价' : '修改评价'),
          ),
          body: snapshot.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator(strokeWidth: 3))
              : snapshot.hasError || questions.isEmpty
                  ? RateLoadError(
                      error: snapshot.error,
                      onRetry: () => setState(() => _config =
                          widget.repository.config(forceRefresh: true)))
                  : _page(questions),
          bottomNavigationBar: ready ? _actions(questions) : null,
        );
      },
    );
  }

  Widget _page(List<RateQuestion> questions) {
    final colors = context.shuyoColors;
    final total = questions.length;
    final atSummary = _index >= total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: (atSummary ? total : _index + 1) / total,
          minHeight: 2,
          backgroundColor: colors.surfaceMuted,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.unit.course.name} · ${widget.unit.teacher.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShuYoTextStyles.meta(color: colors.textTertiary),
                ),
              ),
              Text(atSummary ? '确认' : '${_index + 1} / $total',
                  style: ShuYoTextStyles.meta(color: colors.textSecondary)),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(
              key: ValueKey(_index),
              child: atSummary
                  ? _summary(questions)
                  : _question(questions[_index]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _question(RateQuestion question) {
    final colors = context.shuyoColors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Text(question.title,
            style: ShuYoTextStyles.title(
                color: colors.textPrimary, size: 20, weight: FontWeight.w500)),
        if (question.displayDescription.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(question.displayDescription,
              style: ShuYoTextStyles.meta(color: colors.textTertiary)),
        ],
        const SizedBox(height: 24),
        if (question.isOverall)
          RateOverallPicker(
            question: question,
            value: _overall,
            onChanged: (value) => setState(() => _overall = value),
          )
        else
          RateOptionGrid(
            question: question,
            selected: _answers[question.key] ?? const [],
            onChanged: (value) =>
                setState(() => _answers[question.key] = value),
          ),
      ],
    );
  }

  Widget _summary(List<RateQuestion> questions) {
    final colors = context.shuyoColors;
    final skipped = questions
        .where((q) => !q.isOverall && (_answers[q.key] ?? const []).isEmpty)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Text('确认提交',
            style: ShuYoTextStyles.title(
                color: colors.textPrimary, size: 20, weight: FontWeight.w500)),
        const SizedBox(height: 16),
        RateCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < questions.length; i++)
                _summaryRow(questions[i], i, colors),
            ],
          ),
        ),
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('未作答：${skipped.map((q) => q.title).join('、')}',
              style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        ],
        const SizedBox(height: 12),
        Text('评价匿名展示，其他同学只能看到汇总统计。',
            style: ShuYoTextStyles.meta(color: colors.textTertiary)),
      ],
    );
  }

  Widget _summaryRow(RateQuestion question, int index, ShuYoColors colors) {
    final String value;
    if (question.isOverall) {
      value = _overall == 0
          ? '未选择'
          : '${question.options[_overall - 1].label}（${_overall + 5} 分）';
    } else {
      final selected = _answers[question.key] ?? const [];
      value = selected.isEmpty
          ? '跳过'
          : question.options
              .where((option) => selected.contains(option.key))
              .map((option) => option.label)
              .join('、');
    }
    return InkWell(
      onTap: () => setState(() => _index = index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80,
              child: Text(question.title,
                  style: ShuYoTextStyles.meta(color: colors.textTertiary)),
            ),
            Expanded(
              child: Text(value,
                  style: ShuYoTextStyles.bodyCompact(
                      color: value == '跳过'
                          ? colors.textTertiary
                          : colors.textPrimary,
                      size: 13.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(List<RateQuestion> questions) {
    final total = questions.length;
    final atSummary = _index >= total;
    final current = atSummary ? null : questions[_index];
    final needsAnswer = current != null &&
        current.required &&
        (current.isOverall
            ? _overall == 0
            : (_answers[current.key] ?? const []).isEmpty);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          if (_index > 0)
            TextButton(
              onPressed: _submitting ? null : () => setState(() => _index--),
              child: const Text('上一题'),
            ),
          const Spacer(),
          if (current != null && !current.isOverall && !current.required)
            TextButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() {
                        _answers[current.key] = const [];
                        _index++;
                      }),
              child: const Text('跳过'),
            ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: needsAnswer || _submitting
                ? null
                : atSummary
                    ? () => _submit(questions)
                    : () => setState(() => _index++),
            style: FilledButton.styleFrom(minimumSize: const Size(112, 44)),
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(atSummary
                    ? '提交'
                    : _index == total - 1
                        ? '完成'
                        : '下一题'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit(List<RateQuestion> questions) async {
    if (_submitting) return;
    final draft = RateReviewDraft(overall: _overall, answers: Map.of(_answers));
    final error = draft.validate(questions);
    if (error != null) {
      setState(() => _index = error.questionIndex);
      showRateSnack(context, error.message);
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.repository.saveReview(
        widget.unit.id,
        draft,
      );
      if (!mounted) return;
      showRateSnack(context, widget.existing == null ? '评价已发布' : '评价已更新');
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showRateWriteError(context, widget.repository, error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

/// All questions on one screen, used to edit an existing review.
class RateEditReviewPage extends StatefulWidget {
  const RateEditReviewPage({
    super.key,
    required this.repository,
    required this.unit,
  });

  final CourseReviewRepository repository;
  final RateUnit unit;

  @override
  State<RateEditReviewPage> createState() => _RateEditReviewPageState();
}

class _RateEditReviewPageState extends State<RateEditReviewPage> {
  late Future<(RateCatalogConfig, RateMyReview?)> _future = _load();
  int _overall = 0;
  final Map<String, List<String>> _answers = {};
  List<RateQuestion>? _questions;
  bool _submitting = false;

  Future<(RateCatalogConfig, RateMyReview?)> _load() async {
    _questions = null;
    final config = await widget.repository.config(forceRefresh: true);
    final review = await widget.repository.myReview(widget.unit.id);
    if (!mounted) return (config, review);
    setState(() {
      _overall = review?.overall ?? 0;
      _answers
        ..clear()
        ..addAll({
          for (final entry in (review?.answers ?? const {}).entries)
            entry.key: [...entry.value],
        });
      _questions = config.questions;
    });
    return (config, review);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑评价')),
      body: FutureBuilder<(RateCatalogConfig, RateMyReview?)>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError || snapshot.data!.$1.questions.isEmpty) {
            return RateLoadError(
                error: snapshot.error,
                onRetry: () => setState(() => _future = _load()));
          }
          final questions = snapshot.data!.$1.questions;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(
                '${widget.unit.course.name} · ${widget.unit.teacher.displayName}',
                style: ShuYoTextStyles.meta(color: colors.textTertiary),
              ),
              for (final question in questions) ...[
                const SizedBox(height: 20),
                Text(question.title,
                    style: ShuYoTextStyles.title(
                        color: colors.textPrimary,
                        size: 15.5,
                        weight: FontWeight.w500)),
                if (question.displayDescription.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(question.displayDescription,
                      style: ShuYoTextStyles.meta(color: colors.textTertiary)),
                ],
                const SizedBox(height: 10),
                if (question.isOverall)
                  RateOverallPicker(
                    question: question,
                    value: _overall,
                    onChanged: (value) => setState(() => _overall = value),
                  )
                else
                  RateOptionGrid(
                    question: question,
                    selected: _answers[question.key] ?? const [],
                    onChanged: (value) =>
                        setState(() => _answers[question.key] = value),
                  ),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          onPressed: _questions == null ||
                  _questions!.isEmpty ||
                  _overall == 0 ||
                  _submitting
              ? null
              : _submit,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(_submitting ? '保存中...' : '保存'),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final questions = _questions;
    if (questions == null || questions.isEmpty || _submitting) return;
    final draft = RateReviewDraft(overall: _overall, answers: Map.of(_answers));
    final error = draft.validate(questions);
    if (error != null) {
      showRateSnack(context, error.message);
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.repository.saveReview(
        widget.unit.id,
        draft,
      );
      if (!mounted) return;
      showRateSnack(context, '评价已更新');
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) showRateWriteError(context, widget.repository, error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
