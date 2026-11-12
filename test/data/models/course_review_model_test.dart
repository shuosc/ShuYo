import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_review.dart';

void main() {
  const unitJson = {
    'id': 'u_1',
    'role': 'co',
    'reviewCount': 3,
    'average': 8.3,
    'lastReviewedAt': '2026-10-08T09:00:00.000Z',
    'course': {
      'id': 'GBK001',
      'name': '体育(1)',
      'college': '体育学院',
      'credits': '1'
    },
    'teacher': {
      'id': 't_1',
      'name': '王五',
      'college': '体育学院',
      'title': '讲师',
      'duplicateName': true,
    },
  };

  test('unit summary parses scores and disambiguates duplicate names', () {
    final unit = RateUnit.fromJson(unitJson);
    expect(unit.isCoTeacher, isTrue);
    expect(unit.average, 8.3);
    expect(unit.teacher.displayName, '王五（体育学院）');
    expect(unit.course.metaText, 'GBK001 · 体育学院 · 1 学分');
    final empty = RateUnit.fromJson({...unitJson, 'average': null});
    expect(empty.average, isNull);
  });

  test('lookup results map every server status', () {
    final results = [
      {'status': 'unit', 'unit': unitJson},
      {
        'status': 'course',
        'courseId': 'C1',
        'units': [unitJson]
      },
      {'status': 'search', 'query': '体育(1) 王五'},
      {'status': 'none', 'query': '不存在'},
    ].map(RateLookupResult.fromJson).toList();
    expect(results.map((item) => item.status), RateLookupStatus.values);
    expect(results[0].unit?.id, 'u_1');
    expect(results[1].units.single.id, 'u_1');
    expect(results[2].query, '体育(1) 王五');
  });

  test('schedule course and review draft only send what the server needs', () {
    const course = RateScheduleCourse(
      teachingClassId: '',
      courseCode: '',
      courseName: '计算思维实训',
      teacherName: '赵俊娟',
    );
    expect(course.toJson(), {'courseName': '计算思维实训', 'teacherName': '赵俊娟'});
    const draft = RateReviewDraft(overall: 4, answers: {
      'workload': ['none'],
      'grading': [],
    });
    expect(draft.toJson(), {
      'overall': 4,
      'answers': {
        'workload': ['none'],
        'grading': [],
      },
    });
  });

  const questionJson = {
    'key': 'custom_tags',
    'title': '自定义标签',
    'multiple': true,
    'required': false,
    'options': [
      {'key': 'a', 'label': '选项一'},
      {'key': 'b', 'label': '选项二'},
      {'key': 'c', 'label': '选项三'},
      {'key': 'd', 'label': '选项四'},
    ],
  };

  test('questions keep the server description and selection limit', () {
    final question = RateQuestion.fromJson({
      ...questionJson,
      'maxSelections': 3,
      'description': '多选，最多三项，可跳过',
    });
    expect(question.description, '多选，最多三项，可跳过');
    expect(question.displayDescription, question.description);
    expect(question.maxSelections, 3);
  });

  test('only a missing description uses compatibility text', () {
    final missing = RateQuestion.fromJson(questionJson);
    final hidden = RateQuestion.fromJson({...questionJson, 'description': ''});
    final custom = RateQuestion.fromJson({
      ...questionJson,
      'key': 'grading',
      'multiple': false,
      'description': '单选，可跳过（建议在出分后填写）',
    });
    expect(missing.description, isNull);
    expect(missing.displayDescription, '可多选，可跳过');
    expect(hidden.displayDescription, isEmpty);
    expect(custom.displayDescription, '单选，可跳过（建议在出分后填写）');
  });

  test('compatibility hints use structured rules when provided', () {
    final question = RateQuestion.fromJson({
      ...questionJson,
      'required': true,
      'maxSelections': 2,
    });
    expect(question.displayDescription, '可多选，最多2项，必答');
    expect(RateQuestion.fromJson(questionJson).maxSelections, isNull);
    expect(
        RateQuestion.fromJson({...questionJson, 'maxSelections': 0})
            .maxSelections,
        isNull);
  });

  test('drafts distinguish explicit clears from questions not loaded', () {
    const cleared = RateReviewDraft(overall: 4, answers: {
      'difficulty': [],
      'teacher_tags': [],
    });
    expect(cleared.toJson()['answers'], {
      'difficulty': [],
      'teacher_tags': [],
    });
    const untouched = RateReviewDraft(overall: 4, answers: {});
    expect(untouched.toJson()['answers'], isEmpty);
  });

  test('selection validation is generic and counts unique keys', () {
    final question = RateQuestion.fromJson({
      ...questionJson,
      'maxSelections': 3,
      // Presentation text must not determine the selection rule.
      'description': '自由填写说明',
    });
    const valid = RateReviewDraft(overall: 4, answers: {
      'custom_tags': ['a', 'a', 'b', 'c'],
    });
    expect(valid.validate([question]), isNull);
    const tooMany = RateReviewDraft(overall: 4, answers: {
      'custom_tags': ['a', 'b', 'c', 'd'],
    });
    final error = tooMany.validate([question]);
    expect(error?.questionIndex, 0);
    expect(error?.message, '“自定义标签”最多选择3项');
    expect(tooMany.answers['custom_tags'], ['a', 'b', 'c', 'd']);
    expect(tooMany.validate([RateQuestion.fromJson(questionJson)]), isNull);
  });

  test('validation respects required, single-choice and option keys', () {
    final required = RateQuestion.fromJson({...questionJson, 'required': true});
    const empty = RateReviewDraft(overall: 4, answers: {});
    expect(empty.validate([required])?.message, '请回答“自定义标签”');
    final single = RateQuestion.fromJson({...questionJson, 'multiple': false});
    const two = RateReviewDraft(overall: 4, answers: {
      'custom_tags': ['a', 'b'],
    });
    expect(two.validate([single])?.message, '“自定义标签”只能选择一项');
    const invalid = RateReviewDraft(overall: 4, answers: {
      'custom_tags': ['unknown'],
    });
    expect(invalid.validate([single])?.message, contains('无效选项'));
  });

  test('validation returns the question position without changing answer keys',
      () {
    final first = RateQuestion.fromJson(questionJson);
    final second = RateQuestion.fromJson({
      ...questionJson,
      'key': 'second',
      'maxSelections': 1,
    });
    const draft = RateReviewDraft(overall: 4, answers: {
      'custom_tags': ['d'],
      'second': ['a', 'b'],
    });
    expect(draft.validate([first, second])?.questionIndex, 1);
    expect(draft.validate([second, first])?.questionIndex, 0);
    expect(draft.toJson()['answers'], {
      'custom_tags': ['d'],
      'second': ['a', 'b'],
    });
  });

  test('question stats keep highlight flags', () {
    final stat = RateQuestionStat.fromJson({
      'key': 'attendance_method',
      'title': '签到方式',
      'multiple': true,
      'answered': 2,
      'options': [
        {'key': 'qr', 'label': '扫码签到', 'count': 2, 'percent': 100, 'top': true},
        {'key': 'quiz', 'label': '小测', 'count': 1, 'percent': 50, 'top': false},
      ],
    });
    expect(stat.options.where((option) => option.top).single.key, 'qr');
  });
}
