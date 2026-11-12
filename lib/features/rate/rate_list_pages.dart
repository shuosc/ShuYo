import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import 'rate_navigation.dart';
import 'rate_widgets.dart';

/// Full ranking of one category, paged, with an optional subcategory filter.
class RateRankingPage extends StatefulWidget {
  const RateRankingPage({
    super.key,
    required this.repository,
    required this.category,
    required this.title,
  });

  final CourseReviewRepository repository;
  final String category;
  final String title;

  @override
  State<RateRankingPage> createState() => _RateRankingPageState();
}

class _RateRankingPageState extends State<RateRankingPage> {
  final _items = <RateUnit>[];
  List<String> _subcategories = const [];
  String _sub = '';
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  Future<void> _reload(String sub) async {
    _generation++;
    setState(() {
      _sub = sub;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final page = await widget.repository
          .ranking(widget.category, sub: _sub, page: _page + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _page = page.page;
        _hasMore = page.hasMore;
        if (page.subcategories.isNotEmpty) _subcategories = page.subcategories;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (_subcategories.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  for (final sub in ['', ..._subcategories])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(sub.isEmpty ? '全部' : sub),
                        selected: _sub == sub,
                        showCheckmark: false,
                        onSelected: (_) {
                          if (_sub != sub) unawaited(_reload(sub));
                        },
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.extentAfter < 400) {
                  unawaited(_loadMore());
                }
                return false;
              },
              child: _list(colors),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(ShuYoColors colors) {
    if (_items.isEmpty) {
      if (_error != null) {
        return RateLoadError(error: _error, onRetry: () => _reload(_sub));
      }
      if (_loading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 3));
      }
      return const EmptyState(
        icon: Icons.leaderboard_outlined,
        title: '暂无上榜课程',
        message: '有评价的课程会出现在这里。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('按评分与评价数量综合排序',
              style: ShuYoTextStyles.meta(color: colors.textTertiary)),
        ),
        RateListCard(children: [
          for (var i = 0; i < _items.length; i++)
            RateListTile(
              title: '${i + 1}. ${_items[i].course.name}',
              subtitle:
                  '${_items[i].teacher.displayName} · ${_items[i].course.id}',
              average: _items[i].average,
              count: _items[i].reviewCount,
              onTap: () =>
                  openRateUnit(context, widget.repository, _items[i].id),
            ),
        ]),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
          ),
        if (_error != null && !_loading)
          TextButton(onPressed: _loadMore, child: const Text('加载失败，点击重试')),
      ],
    );
  }
}

class RateCollegePage extends StatefulWidget {
  const RateCollegePage({
    super.key,
    required this.repository,
    required this.college,
  });

  final CourseReviewRepository repository;
  final String college;

  @override
  State<RateCollegePage> createState() => _RateCollegePageState();
}

class _RateCollegePageState extends State<RateCollegePage> {
  late Future<List<RateCourseSummary>> _future =
      widget.repository.collegeCourses(widget.college);
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.college)),
      body: FutureBuilder<List<RateCourseSummary>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return RateLoadError(
              error: snapshot.error,
              onRetry: () => setState(() =>
                  _future = widget.repository.collegeCourses(widget.college)),
            );
          }
          final keyword = _filter.text.trim();
          final courses = (snapshot.data ?? const <RateCourseSummary>[])
              .where((item) =>
                  keyword.isEmpty ||
                  item.course.name.contains(keyword) ||
                  item.course.id.contains(keyword))
              .toList();
          return ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              TextField(
                controller: _filter,
                decoration: const InputDecoration(
                  hintText: '筛选本学院课程',
                  prefixIcon: Icon(Icons.filter_list),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              if (courses.isEmpty)
                const EmptyState(
                  icon: Icons.search_off,
                  title: '没有匹配的课程',
                  message: '换个关键词试试。',
                )
              else
                RateListCard(children: [
                  for (final course in courses)
                    RateListTile(
                      title: course.course.name,
                      subtitle:
                          '${course.course.id} · ${course.teacherCount} 位教师',
                      average: course.average,
                      count: course.reviewCount,
                      onTap: () => openRateCourse(
                          context, widget.repository, course.course.id),
                    ),
                ]),
            ],
          );
        },
      ),
    );
  }
}
