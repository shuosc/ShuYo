import 'package:flutter/foundation.dart';

import '../../data/models/course_recording.dart';
import '../../data/models/vod_ppt.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_auth_exception.dart';

typedef RecordingNotesLoader = Future<List<VodPptSlide>> Function(
  int lessonId, {
  required bool forceRefresh,
});

/// A lesson's notes state, independent from video, tabs and scroll widgets.
@immutable
class RecordingNotesState {
  const RecordingNotesState({
    this.lessonId,
    this.slides = const [],
    this.loading = false,
    this.error,
    this.isLive = false,
  });

  final int? lessonId;
  final List<VodPptSlide> slides;
  final bool loading;
  final String? error;
  final bool isLive;

  /// Live lessons are always zero. Recording loads and failures remain unknown.
  int? get count => isLive
      ? 0
      : slides.isNotEmpty
          ? slides.length
          : lessonId != null && !loading && error == null
              ? 0
              : null;
}

/// Owns asynchronous note loading without rebuilding the player route.
///
/// Completions are bound to a lesson revision. Pull refreshes retain known
/// content while pending, and a failed refresh never discards existing notes.
class RecordingNotesController extends ValueNotifier<RecordingNotesState> {
  RecordingNotesController({
    required this.teachingClassId,
    this.loader,
  }) : super(const RecordingNotesState());

  final int teachingClassId;
  final RecordingNotesLoader? loader;
  int _revision = 0;
  bool _disposed = false;

  void invalidate() {
    if (_disposed) return;
    _revision++;
    value = const RecordingNotesState();
  }

  /// Returns a message only when retained content needs a non-blocking warning.
  Future<String?> load(VodLesson lesson, {bool forceRefresh = false}) async {
    if (_disposed ||
        !forceRefresh &&
            value.lessonId == lesson.id &&
            value.isLive == lesson.isLive) {
      return null;
    }
    final revision = ++_revision;
    if (lesson.isLive) {
      value = RecordingNotesState(lessonId: lesson.id, isLive: true);
      return null;
    }
    final previous = value;
    final pullRefresh =
        forceRefresh && previous.lessonId == lesson.id &&
        !previous.isLive && !previous.loading;
    final supported =
        lesson.id > 0 && lesson.teachingClassId == teachingClassId;
    final canLoad = supported && loader != null;
    if (!canLoad) {
      value = RecordingNotesState(
        lessonId: lesson.id,
        error: supported ? '暂时无法加载这节课的 PPT 笔记，请稍后下拉重试' : '请先选择课次，再查看 PPT 笔记',
      );
      return null;
    }
    if (!pullRefresh) {
      value = RecordingNotesState(lessonId: lesson.id, loading: true);
    }
    try {
      final slides = await loader!(lesson.id, forceRefresh: forceRefresh);
      if (_disposed || revision != _revision) return null;
      value = RecordingNotesState(
        lessonId: lesson.id,
        slides: List.unmodifiable(slides),
      );
    } on Object catch (error) {
      if (_disposed || revision != _revision) return null;
      final message = switch (error) {
        VodWebVpnSessionExpiredException() ||
        VodWebVpnAuthRequiredException() =>
          'WebVPN 连接已失效，请恢复连接后重试',
        VodSessionExpiredException() => '校园账户登录已失效，请重新进入录播平台后重试',
        VodPermissionException() => '平台暂未允许读取这节课的 PPT 笔记，请稍后下拉重试',
        VodInvalidResponseException() => '平台返回的 PPT 笔记数据异常，请稍后下拉重试',
        _ => '暂时无法加载这节课的 PPT 笔记，请稍后下拉重试',
      };
      if (pullRefresh && previous.slides.isNotEmpty) return message;
      value = RecordingNotesState(lessonId: lesson.id, error: message);
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
