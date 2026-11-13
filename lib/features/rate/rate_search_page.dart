import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'rate_navigation.dart';
import 'rate_widgets.dart';

class RateSearchPage extends StatefulWidget {
  const RateSearchPage({
    super.key,
    required this.repository,
    this.initialQuery = '',
  });

  final CourseReviewRepository repository;
  final String initialQuery;

  @override
  State<RateSearchPage> createState() => _RateSearchPageState();
}

class _RateSearchPageState extends State<RateSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  int _requestId = 0;
  String _query = '';
  RateSearchResult _result = RateSearchResult.empty;
  Object? _error;
  bool _loading = false;

  CourseReviewRepository get _repo => widget.repository;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      unawaited(_search(widget.initialQuery));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
        const Duration(milliseconds: 300), () => unawaited(_search(value)));
  }

  Future<void> _search(String value) async {
    final query = value.trim();
    final id = ++_requestId;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _result = RateSearchResult.empty;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await _repo.search(query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _query = query;
        _result = result;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted && id == _requestId) setState(() => _error = error);
    } finally {
      if (mounted && id == _requestId) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索课程')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RateSearchField(
              controller: _controller,
              autofocus: widget.initialQuery.isEmpty,
              onChanged: _onChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                unawaited(_search(value));
              },
            ),
          ),
          SizedBox(
            height: 2,
            child:
                _loading ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _results() {
    final colors = context.shuyoColors;
    if (_error != null) {
      return RateLoadError(
          error: _error, onRetry: () => _search(_controller.text));
    }
    if (_query.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '可以输入课程名、教师名或课程号，用空格组合多个条件，例如「高等数学 王」。',
          style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
        ),
      );
    }
    if (_result.isEmpty && !_loading) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有找到相关课程',
        message: '换个关键词试试，或者告诉我们缺少了什么。',
        action: TextButton(
          onPressed: () => openRateFeedbackComposer(context, _repo),
          child: const Text('反馈缺失的课程'),
        ),
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (_result.units.isNotEmpty) ...[
          const RateSectionTitle(title: '课程与教师'),
          RateListCard(children: [
            for (final unit in _result.units)
              RateListTile(
                title: unit.course.name,
                subtitle: '${unit.teacher.displayName} · ${unit.course.id}',
                average: unit.average,
                count: unit.reviewCount,
                onTap: () => openRateUnit(context, _repo, unit.id),
              ),
          ]),
          const SizedBox(height: 16),
        ],
        if (_result.courses.isNotEmpty) ...[
          const RateSectionTitle(title: '课程'),
          RateListCard(children: [
            for (final course in _result.courses) _courseTile(course),
          ]),
          const SizedBox(height: 16),
        ],
        if (_result.teachers.isNotEmpty) ...[
          const RateSectionTitle(title: '教师'),
          RateListCard(children: [
            for (final teacher in _result.teachers)
              RateListTile(
                title: teacher.teacher.name,
                subtitle: [
                  teacher.teacher.college,
                  teacher.teacher.title,
                  '${teacher.courseCount} 门课程',
                ].where((part) => part.isNotEmpty).join(' · '),
                average: teacher.average,
                count: teacher.reviewCount,
                onTap: () =>
                    openRateTeacher(context, _repo, teacher.teacher.id),
              ),
          ]),
        ],
      ],
    );
  }

  Widget _courseTile(RateCourseSummary course) => RateListTile(
        title: course.course.name,
        subtitle:
            '${course.course.id} · ${course.course.college} · ${course.teacherCount} 位教师',
        average: course.average,
        count: course.reviewCount,
        onTap: () => openRateCourse(context, _repo, course.course.id),
      );
}
