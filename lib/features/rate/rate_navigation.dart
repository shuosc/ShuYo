import 'package:material_ui/material_ui.dart';

import '../../data/models/course_review.dart';
import '../../data/repositories/course_review_repository.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../settings/student_identity_page.dart';
import 'rate_detail_pages.dart';
import 'rate_feedback_pages.dart';
import 'rate_list_pages.dart';
import 'rate_profile_page.dart';
import 'rate_publish_page.dart';
import 'rate_search_page.dart';
import 'rate_widgets.dart';

Future<T?> _push<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(shuyoRoute(builder: (_) => page));

Future<void> openRateUnit(
        BuildContext context, CourseReviewRepository repo, String unitId) =>
    _push(context, RateUnitPage(repository: repo, unitId: unitId));

Future<void> openRateCourse(
  BuildContext context,
  CourseReviewRepository repo,
  String courseId, {
  List<String> highlightedUnitIds = const [],
}) =>
    _push(
      context,
      RateCoursePage(
        repository: repo,
        courseId: courseId,
        highlightedUnitIds: highlightedUnitIds,
      ),
    );

Future<void> openRateTeacher(
        BuildContext context, CourseReviewRepository repo, String teacherId) =>
    _push(context, RateTeacherPage(repository: repo, teacherId: teacherId));

Future<void> openRateSearch(BuildContext context, CourseReviewRepository repo,
        {String query = ''}) =>
    _push(context, RateSearchPage(repository: repo, initialQuery: query));

Future<void> openRateRanking(BuildContext context, CourseReviewRepository repo,
        String category, String title) =>
    _push(context,
        RateRankingPage(repository: repo, category: category, title: title));

Future<void> openRateCollege(
        BuildContext context, CourseReviewRepository repo, String college) =>
    _push(context, RateCollegePage(repository: repo, college: college));

Future<void> openRateProfile(
        BuildContext context, CourseReviewRepository repo) =>
    _push(context, RateProfilePage(repository: repo));

Future<void> openRateFeedbackList(
        BuildContext context, CourseReviewRepository repo) =>
    _push(context, RateFeedbackListPage(repository: repo));

/// Opens the course review feedback form linked to a unit or a course.
Future<void> openRateFeedbackComposer(
  BuildContext context,
  CourseReviewRepository repo, {
  RateUnit? unit,
  RateCourseRef? course,
}) async {
  if (!await ensureRateIdentity(context, repo)) return;
  if (!context.mounted) return;
  await _push(
    context,
    RateFeedbackComposerPage(repository: repo, unit: unit, course: course),
  );
}

/// Publishing flow; returns true when a review was saved.
Future<bool> openRatePublish(
  BuildContext context,
  CourseReviewRepository repo,
  RateUnit unit, {
  RateMyReview? existing,
}) async {
  if (!await ensureRateIdentity(context, repo)) return false;
  if (!context.mounted) return false;
  final saved = await _push<bool>(
    context,
    RatePublishPage(repository: repo, unit: unit, existing: existing),
  );
  return saved == true;
}

/// Reuses a verified session, otherwise runs the existing verification page
/// and continues only when it succeeded.
Future<bool> ensureRateIdentity(
    BuildContext context, CourseReviewRepository repo) async {
  if (repo.isDemo) {
    showRateSnack(context, '演示模式暂不支持发布评价');
    return false;
  }
  final identity = repo.studentIdentityService;
  if (await identity.ensureForProtectedAction()) return true;
  if (!context.mounted) return false;
  await _push<void>(context, StudentIdentityPage(service: identity));
  if (!context.mounted) return false;
  if (await identity.ensureForProtectedAction()) return true;
  if (context.mounted) showRateSnack(context, '完成身份认证后才能发布评价和反馈');
  return false;
}

/// Shows a message for a failed write and offers verification when needed.
void showRateWriteError(
    BuildContext context, CourseReviewRepository repo, Object error) {
  if (error is CourseReviewIdentityRequired) {
    showRateSnack(
      context,
      '请先完成身份认证',
      action: SnackBarAction(
        label: '去认证',
        onPressed: () => ensureRateIdentity(context, repo),
      ),
    );
    return;
  }
  showRateSnack(context, error.toString());
}
