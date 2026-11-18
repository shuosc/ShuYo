import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/demo/demo_course_review_repository.dart';
import 'package:shuyo/data/demo/demo_data_bundle.dart';
import 'package:shuyo/data/demo/demo_repositories.dart';
import 'package:shuyo/data/models/academic_schedule.dart';
import 'package:shuyo/data/models/course_review.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AcademicSchedule schedule;

  setUpAll(() async => schedule = (await DemoDataBundle.load()).schedule);

  DemoCourseReviewRepository newSession() {
    final timetable = DemoAcademicScheduleRepository(schedule);
    final repository = DemoCourseReviewRepository(
      schedule: schedule,
      scheduleRepository: timetable,
      scheduleLoader: timetable.loadCachedSchedule,
    );
    addTearDown(repository.dispose);
    return repository;
  }

  test('the bundled timetable, course catalog and rankings work offline',
      () async {
    final repository = newSession();
    final matches = await repository.matchSchedule();
    expect(matches, isNotEmpty);
    expect(matches.map((match) => match.result.status),
        everyElement(RateLookupStatus.unit));
    final unit = matches.first.result.unit!;
    final search = await repository.search(unit.course.id.toLowerCase());
    expect(search.courses.single.course.name, unit.course.name);
    expect(search.units.single.id, unit.id);
    expect((await repository.course(unit.course.id)).units.single.id, unit.id);
    expect((await repository.teacher(unit.teacher.id)).units,
        contains(predicate<RateUnit>((match) => match.id == unit.id)));
    expect(await repository.collegeCourses(unit.course.college), isNotEmpty);

    final ranking = (await repository.home()).rankings.single;
    final page =
        await repository.ranking(ranking.key, sub: unit.course.college);
    expect(page.items, isNotEmpty);
    expect(page.items.map((item) => item.course.college),
        everyElement(unit.course.college));
  });

  test('creating, editing and deleting a review updates the current demo only',
      () async {
    final repository = newSession();
    final match = (await repository.matchSchedule()).first;
    final id = match.result.unit!.id;
    final baseline = await repository.unit(id);
    expect(await repository.myReview(id), isNull);

    final review = await repository.saveReview(
        id,
        const RateReviewDraft(overall: 5, answers: {
          'grading': ['fair']
        }));
    expect((await repository.myReviews()).reviews.single.id, review.id);
    final withReview = await repository.unit(id);
    expect(withReview.unit.reviewCount, baseline.unit.reviewCount + 1);
    expect(withReview.stats[1].answered, baseline.stats[1].answered + 1);

    final edited = await repository.saveReview(
        id, const RateReviewDraft(overall: 1, answers: {'grading': []}));
    expect(edited.id, review.id);
    expect((await repository.myReview(id))?.overall, 1);
    expect((await repository.unit(id)).unit.reviewCount,
        withReview.unit.reviewCount);
    expect((await newSession().myReviews()).reviews, isEmpty);

    await repository.deleteReview(id);
    expect((await repository.myReviews()).reviews, isEmpty);
    expect((await repository.unit(id)).unit.reviewCount,
        baseline.unit.reviewCount);
    await expectLater(repository.feedback(), throwsA(isA<Exception>()));
  });
}
