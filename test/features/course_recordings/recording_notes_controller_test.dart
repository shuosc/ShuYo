import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/course_recording.dart';
import 'package:shuyo/data/models/vod_ppt.dart';
import 'package:shuyo/data/services/vod_api_client.dart';
import 'package:shuyo/data/services/vod_auth_exception.dart';
import 'package:shuyo/features/course_recordings/recording_notes_controller.dart';

void main() {
  const first =
      VodLesson(id: 1, teachingClassId: 10, name: '课次一', isPlayable: true);
  const second =
      VodLesson(id: 2, teachingClassId: 10, name: '课次二', isPlayable: true);
  const note = VodPptSlide(
      id: 'one', imageUrl: null, position: Duration.zero, text: '识别内容');

  test('late completions never replace the selected lesson notes', () async {
    final pending = <int, Completer<List<VodPptSlide>>>{};
    final controller = RecordingNotesController(
      teachingClassId: 10,
      loader: (id, {required forceRefresh}) =>
          (pending[id] = Completer<List<VodPptSlide>>()).future,
    );
    final firstLoad = controller.load(first);
    final secondLoad = controller.load(second);
    pending[2]!.complete([]);
    await secondLoad;
    expect(controller.value.lessonId, 2);
    expect(controller.value.count, 0);
    pending[1]!.complete([note]);
    await firstLoad;
    expect(controller.value.lessonId, 2);
    expect(controller.value.slides, isEmpty);
    expect(controller.value.count, 0);
    controller.dispose();
  });

  test('refresh keeps known notes and returns a non-blocking failure',
      () async {
    var requests = 0;
    final controller = RecordingNotesController(
      teachingClassId: 10,
      loader: (id, {required forceRefresh}) async {
        requests++;
        if (forceRefresh) throw const VodNetworkException();
        return [note];
      },
    );
    await controller.load(first);
    final settled = controller.value;
    var changes = 0;
    controller.addListener(() => changes++);
    expect(await controller.load(first), isNull);
    expect(requests, 1);
    expect(await controller.load(first, forceRefresh: true), isNotNull);
    expect(controller.value, same(settled));
    expect(controller.value.count, 1);
    expect(changes, 0);
    controller.dispose();
  });

  for (final error in <Object>[
    const VodWebVpnSessionExpiredException(),
    const VodWebVpnAuthRequiredException(),
  ]) {
    test('${error.runtimeType} identifies WebVPN recovery on initial load',
        () async {
      final controller = RecordingNotesController(
        teachingClassId: 10,
        loader: (id, {required forceRefresh}) async => throw error,
      );

      expect(await controller.load(first), isNull);
      expect(controller.value.error, 'WebVPN 连接已失效，请恢复连接后重试');
      expect(controller.value.loading, isFalse);
      expect(controller.value.count, isNull);
      controller.dispose();
    });

    test('${error.runtimeType} retains notes and reports WebVPN recovery',
        () async {
      final controller = RecordingNotesController(
        teachingClassId: 10,
        loader: (id, {required forceRefresh}) async {
          if (forceRefresh) throw error;
          return [note];
        },
      );
      await controller.load(first);
      final settled = controller.value;

      expect(await controller.load(first, forceRefresh: true),
          'WebVPN 连接已失效，请恢复连接后重试');
      expect(controller.value, same(settled));
      expect(controller.value.slides, [note]);
      expect(controller.value.error, isNull);
      expect(controller.value.count, 1);
      controller.dispose();
    });
  }

  test('campus session expiry keeps its campus account message', () async {
    final controller = RecordingNotesController(
      teachingClassId: 10,
      loader: (id, {required forceRefresh}) async =>
          throw const VodSessionExpiredException(),
    );

    await controller.load(first);
    expect(controller.value.error, '校园账户登录已失效，请重新进入录播平台后重试');
    controller.dispose();
  });

  test('confirmed empty, pending refresh and failed refresh stay distinct',
      () async {
    Completer<List<VodPptSlide>>? refresh;
    final controller = RecordingNotesController(
      teachingClassId: 10,
      loader: (id, {required forceRefresh}) => forceRefresh
          ? (refresh = Completer<List<VodPptSlide>>()).future
          : Future.value([]),
    );
    await controller.load(first);
    expect(controller.value.count, 0);
    final request = controller.load(first, forceRefresh: true);
    expect(controller.value.loading, isFalse);
    expect(controller.value.count, 0);
    refresh!.completeError(const VodInvalidResponseException());
    await request;
    expect(controller.value.count, isNull);
    expect(controller.value.error, isNotNull);
    controller.dispose();
  });

  test('recovery invalidates old work and disposal ignores completions',
      () async {
    final pending = <Completer<List<VodPptSlide>>>[];
    final controller = RecordingNotesController(
      teachingClassId: 10,
      loader: (id, {required forceRefresh}) {
        final request = Completer<List<VodPptSlide>>();
        pending.add(request);
        return request.future;
      },
    );
    final firstLoad = controller.load(first);
    controller.invalidate();
    expect(controller.value.count, isNull);
    final newLoad = controller.load(first);
    pending.first.complete([note]);
    await firstLoad;
    expect(controller.value.loading, isTrue);
    controller.dispose();
    pending.last.complete([]);
    await newLoad;
  });
}
