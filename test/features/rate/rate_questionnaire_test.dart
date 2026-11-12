import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/data/models/course_review.dart';
import 'package:shuyo/data/repositories/academic_schedule_repository.dart';
import 'package:shuyo/data/repositories/course_review_repository.dart';
import 'package:shuyo/data/services/student_identity_service.dart';
import 'package:shuyo/features/rate/rate_detail_pages.dart';
import 'package:shuyo/features/rate/rate_publish_page.dart';
import 'package:shuyo/features/rate/rate_question_widgets.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

const _overall = RateQuestion(
  key: 'overall',
  title: '总体评价',
  multiple: false,
  required: true,
  description: '后端总体说明',
  options: [
    RateOption(key: '1', label: '不推荐'),
    RateOption(key: '2', label: '谨慎选择'),
    RateOption(key: '3', label: '中规中矩'),
    RateOption(key: '4', label: '值得一选'),
    RateOption(key: '5', label: '强烈推荐'),
  ],
);
const _difficulty = RateQuestion(
  key: 'difficulty',
  title: '课程难度',
  multiple: false,
  required: false,
  description: '',
  options: [
    RateOption(key: 'easy', label: '比较容易'),
    RateOption(key: 'hard', label: '比较困难'),
  ],
);
const _tagOptions = [
  RateOption(key: 'a', label: '风趣幽默'),
  RateOption(key: 'b', label: '条理清晰'),
  RateOption(key: 'c', label: '深入浅出'),
  RateOption(key: 'd', label: '启发思考'),
];
const _tags = RateQuestion(
  key: 'teacher_tags',
  title: '你想送给老师的标签（如果有的话）',
  multiple: true,
  required: false,
  description: '多选，最多三项，可跳过',
  maxSelections: 3,
  options: _tagOptions,
);

RateCatalogConfig _config(List<RateQuestion> questions) => RateCatalogConfig(
      questions: questions,
      categories: const [],
      feedbackKinds: const [],
    );

final _unit = RateUnit.fromJson({
  'id': 'unit',
  'role': 'lead',
  'reviewCount': 1,
  'average': 9,
  'course': {'id': 'course', 'name': '测试课程', 'college': '测试学院', 'credits': '2'},
  'teacher': {'id': 'teacher', 'name': '测试教师'},
});

RateMyReview _review(Map<String, List<String>> answers) => RateMyReview(
      id: 'review',
      unitId: _unit.id,
      overall: 4,
      answers: answers,
      updatedAt: null,
    );

class _ReviewRepository extends CourseReviewRepository {
  _ReviewRepository({required this.configuration, this.review})
      : super(
          studentIdentityService: StudentIdentityService(),
          scheduleRepository: AcademicScheduleRepository(),
        );

  RateCatalogConfig configuration;
  RateMyReview? review;
  final refreshes = <bool>[];
  final saved = <RateReviewDraft>[];

  @override
  Future<RateCatalogConfig> config({bool forceRefresh = false}) async {
    refreshes.add(forceRefresh);
    return configuration;
  }

  @override
  Future<RateMyReview?> myReview(String unitId) async => review;

  @override
  Future<RateMyReview> saveReview(String unitId, RateReviewDraft draft) async {
    saved.add(draft);
    return _review(draft.answers);
  }

  @override
  Future<RateUnitDetail> unit(String id) async => RateUnitDetail(
        unit: _unit,
        stats: [
          RateQuestionStat(
            key: _tags.key,
            title: _tags.title,
            multiple: true,
            answered: 1,
            options: const [],
          ),
        ],
      );

  @override
  void dispose() {
    studentIdentityService.dispose();
    super.dispose();
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(420, 1000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    key: UniqueKey(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: const Scaffold(body: Text('返回页')),
    routes: {'/review': (_) => page},
    initialRoute: '/review',
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  _ReviewRepository repository(
    List<RateQuestion> questions, {
    RateMyReview? review,
  }) {
    final repo = _ReviewRepository(
      configuration: _config(questions),
      review: review,
    );
    addTearDown(repo.dispose);
    return repo;
  }

  for (final question in [_difficulty, _tags]) {
    testWidgets(
        '${question.multiple ? 'multiple' : 'single'}-choice options show circular checks only when selected',
        (tester) async {
      var selected = <String>[];
      await _pumpPage(
          tester,
          Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => RateOptionGrid(
                      question: question,
                      selected: selected,
                      onChanged: (value) => setState(() => selected = value),
                    )),
          ));

      void expectIndicators() {
        expect(find.byIcon(Icons.check_box_rounded), findsNothing);
        expect(
            find.byIcon(Icons.check_box_outline_blank_rounded), findsNothing);
        final icons = find.byIcon(Icons.check_circle_rounded);
        expect(icons, findsNWidgets(question.options.length));
        final colors = tester.element(find.byType(RateOptionGrid)).shuyoColors;
        expect(
            tester.widgetList<Icon>(icons).map((icon) => icon.color).toList(), [
          for (final option in question.options)
            selected.contains(option.key) ? colors.accent : Colors.transparent,
        ]);
      }

      expectIndicators();
      final first = question.options[0];
      final second = question.options[1];
      await _tap(tester, first.label);
      expect(selected, [first.key]);
      expectIndicators();
      await _tap(tester, second.label);
      expect(
          selected, question.multiple ? [first.key, second.key] : [second.key]);
      expectIndicators();
      await _tap(tester, second.label);
      expect(selected, question.multiple ? [first.key] : <String>[]);
      expectIndicators();
    });
  }

  testWidgets(
      'a generic selection limit blocks additions but allows replacement',
      (tester) async {
    const question = RateQuestion(
      key: 'custom_tags',
      title: '自定义题目',
      multiple: true,
      required: false,
      maxSelections: 3,
      options: _tagOptions,
    );
    var selected = ['a', 'b', 'c'];
    await _pumpPage(
        tester,
        Scaffold(
          body: StatefulBuilder(
              builder: (context, setState) => RateOptionGrid(
                    question: question,
                    selected: selected,
                    onChanged: (value) => setState(() => selected = value),
                  )),
        ));
    await _tap(tester, '启发思考');
    expect(selected, ['a', 'b', 'c']);
    expect(find.text('最多选择3项'), findsOneWidget);
    await _tap(tester, '条理清晰');
    await _tap(tester, '启发思考');
    expect(selected, ['a', 'c', 'd']);
  });

  testWidgets('multiple-choice questions without a limit remain unrestricted',
      (tester) async {
    const question = RateQuestion(
      key: 'attendance_method',
      title: '签到方式',
      multiple: true,
      required: false,
      options: _tagOptions,
    );
    var selected = <String>[];
    await _pumpPage(
        tester,
        Scaffold(
          body: StatefulBuilder(
              builder: (context, setState) => RateOptionGrid(
                    question: question,
                    selected: selected,
                    onChanged: (value) => setState(() => selected = value),
                  )),
        ));
    for (final option in _tagOptions) {
      await _tap(tester, option.label);
    }
    expect(selected, ['a', 'b', 'c', 'd']);
  });

  testWidgets(
      'publishing uses server hints and one stable questionnaire snapshot',
      (tester) async {
    final repo = repository([_overall, _tags, _difficulty]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({}),
        ));
    expect(find.text('后端总体说明'), findsOneWidget);
    expect(repo.refreshes, [true]);
    repo.configuration = _config([_overall, _difficulty, _tags]);
    await _tap(tester, '下一题');
    expect(find.text(_tags.description!), findsOneWidget);
    expect(
        tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).question.key,
        'teacher_tags');
    await _tap(tester, '下一题');
    expect(find.text('单选，可跳过'), findsNothing);
    expect(
        tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).question.key,
        'difficulty');
    expect(repo.refreshes, [true]);
  });

  testWidgets('re-entering the publisher refreshes the configuration',
      (tester) async {
    final repo = repository([_overall, _difficulty]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({}),
        ));
    repo.configuration = _config([_overall, _tags]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({}),
        ));
    await _tap(tester, '下一题');
    expect(find.text(_tags.title), findsOneWidget);
    expect(repo.refreshes, [true, true]);
  });

  testWidgets(
      'skipping an existing new answer explicitly clears only that answer',
      (tester) async {
    final repo = repository([_overall, _difficulty]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({
            'difficulty': ['hard'],
            'workload': ['none']
          }),
        ));
    await _tap(tester, '下一题');
    expect(tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).selected,
        ['hard']);
    await _tap(tester, '跳过');
    await _tap(tester, '提交');
    expect(repo.saved.single.toJson()['answers'], {
      'difficulty': [],
      'workload': ['none'],
    });
  });

  testWidgets('reordered questions and options refill and save by stable keys',
      (tester) async {
    final reversed = RateQuestion(
      key: _difficulty.key,
      title: _difficulty.title,
      multiple: false,
      required: false,
      options: _difficulty.options.reversed.toList(),
    );
    final repo = repository([_overall, _tags, reversed]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({
            'difficulty': ['hard'],
            'teacher_tags': ['c']
          }),
        ));
    await _tap(tester, '下一题');
    expect(tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).selected,
        ['c']);
    await _tap(tester, '下一题');
    expect(tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).selected,
        ['hard']);
    await _tap(tester, '完成');
    await _tap(tester, '提交');
    expect(repo.saved.single.answers, {
      'difficulty': ['hard'],
      'teacher_tags': ['c'],
    });
  });

  testWidgets(
      'the editor displays hints, hides empty hints and clears both new answers',
      (tester) async {
    final repo = repository([_overall, _difficulty, _tags],
        review: _review({
          'difficulty': ['hard'],
          'teacher_tags': ['a'],
        }));
    await _pumpPage(tester, RateEditReviewPage(repository: repo, unit: _unit));
    expect(find.text('后端总体说明'), findsOneWidget);
    expect(find.text(_tags.description!), findsOneWidget);
    expect(find.text('单选，可跳过'), findsNothing);
    expect(find.text('可多选'), findsNothing);
    expect(repo.refreshes, [true]);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNotNull);
    await _tap(tester, '比较困难');
    await _tap(tester, '风趣幽默');
    await _tap(tester, '保存');
    expect(repo.saved.single.toJson()['answers'], {
      'difficulty': [],
      'teacher_tags': [],
    });
  });

  testWidgets(
      'publish submission validates stale answers without truncating them',
      (tester) async {
    final repo = repository([_overall, _tags]);
    await _pumpPage(
        tester,
        RatePublishPage(
          repository: repo,
          unit: _unit,
          existing: _review({
            'teacher_tags': ['a', 'b', 'c', 'd']
          }),
        ));
    await _tap(tester, '下一题');
    await _tap(tester, '完成');
    await _tap(tester, '提交');
    expect(repo.saved, isEmpty);
    expect(find.text('“${_tags.title}”最多选择3项'), findsOneWidget);
    expect(tester.widget<RateOptionGrid>(find.byType(RateOptionGrid)).selected,
        ['a', 'b', 'c', 'd']);
  });

  testWidgets(
      'editor submission validates limits and lets the user remove an excess choice',
      (tester) async {
    final repo = repository([_overall, _tags],
        review: _review({
          'teacher_tags': ['a', 'b', 'c', 'd'],
        }));
    await _pumpPage(tester, RateEditReviewPage(repository: repo, unit: _unit));
    await _tap(tester, '保存');
    expect(repo.saved, isEmpty);
    expect(find.text('“${_tags.title}”最多选择3项'), findsOneWidget);
    await _tap(tester, '风趣幽默');
    await _tap(tester, '保存');
    expect(repo.saved.single.answers['teacher_tags'], ['b', 'c', 'd']);
  });

  testWidgets('editor long titles and hints wrap on a narrow screen',
      (tester) async {
    final repo = repository([_overall, _tags], review: _review({}));
    await _pumpPage(
      tester,
      RateEditReviewPage(repository: repo, unit: _unit),
      size: const Size(320, 800),
      textScale: 1.3,
    );
    await tester.ensureVisible(find.text(_tags.description!));
    await tester.pumpAndSettle();
    expect(find.text(_tags.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('statistics long titles wrap beside the answer count',
      (tester) async {
    final repo = repository([_overall, _tags]);
    await _pumpPage(
      tester,
      RateUnitPage(repository: repo, unitId: _unit.id),
      size: const Size(280, 800),
      textScale: 1.3,
    );
    await tester.ensureVisible(find.text(_tags.title));
    await tester.pumpAndSettle();
    expect(find.text('1 人回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
