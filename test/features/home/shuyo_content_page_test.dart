import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuyo/data/repositories/shuyo_content_repository.dart';
import 'package:shuyo/features/home/shuyo_content_page.dart';
import 'package:shuyo/shared/widgets/fullscreen_image_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('content repository uses saved list when offline', () async {
    var online = true;
    final client = MockClient((request) async {
      if (!online) throw const ShuyoContentException('offline');
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'success': true,
          'data': [
            {
              'id': 'ann_1',
              'title': '欢迎使用',
              'content': '公告正文',
              'createdAt': '2026-10-08T00:00:00Z',
              'updatedAt': '2026-10-08T00:00:00Z',
            }
          ],
        })),
        200,
      );
    });
    final repository = ShuyoContentRepository(
      client: client,
      baseUrl: 'https://api.shuyo.work',
    );
    final fresh = await repository.load(ShuyoContentKind.announcements);
    expect(fresh.fromCache, isFalse);
    online = false;
    final cached = await repository.load(ShuyoContentKind.announcements);
    expect(cached.fromCache, isTrue);
    expect(cached.items.single.title, '欢迎使用');
  });

  test('old backend returns a clear message without breaking school notices',
      () async {
    final repository = ShuyoContentRepository(
      client: MockClient((request) async => http.Response('', 404)),
      baseUrl: 'https://api.shuyo.work',
    );
    await expectLater(
      repository.load(ShuyoContentKind.tips),
      throwsA(isA<ShuyoContentException>()
          .having((error) => error.message, 'message', contains('暂未提供'))),
    );
  });

  testWidgets('notifications default to tips with notice rows and tabs',
      (tester) async {
    final client = MockClient((request) async {
      final tips = request.url.path.endsWith('/tips');
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'success': true,
          'data': [
            {
              'id': tips ? 'tip_1' : 'ann_1',
              'title': tips ? '快速上手' : '欢迎使用',
              'content': tips
                  ? '# 第一步\n\n![外部图片](https://example.org/image.png)'
                  : '公告正文',
              'createdAt': '2026-10-08T00:00:00Z',
              'updatedAt': '2026-10-08T00:00:00Z',
            }
          ],
        })),
        200,
      );
    });
    final repository = ShuyoContentRepository(
      client: client,
      baseUrl: 'https://api.shuyo.work',
    );
    await tester.pumpWidget(MaterialApp(
      home: ShuyoContentPage(repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('使用提示'), findsOneWidget);
    expect(find.text('系统公告'), findsOneWidget);
    expect(find.text('快速上手'), findsOneWidget);
    expect(find.textContaining('第一步'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byType(SlideTransition), findsWidgets);
    final tabBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
    final tipRow = find
        .ancestor(of: find.text('快速上手'), matching: find.byType(InkWell))
        .first;
    expect(tester.getTopLeft(tipRow).dy, closeTo(tabBottom, 0.5));
    await tester.tap(find.text('快速上手'));
    await tester.pumpAndSettle();
    expect(find.text('第一步'), findsOneWidget);
    expect(find.text('图片地址不可用'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统公告'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用'), findsOneWidget);
    expect(find.text('公告正文'), findsOneWidget);
    final announcementRow = find
        .ancestor(of: find.text('欢迎使用'), matching: find.byType(InkWell))
        .first;
    expect(tester.getTopLeft(announcementRow).dy, closeTo(tabBottom, 0.5));
    await tester.tap(find.text('欢迎使用'));
    await tester.pumpAndSettle();
    expect(find.text('公告正文'), findsOneWidget);
  });

  testWidgets('tip images reserve space and open the full screen viewer',
      (tester) async {
    const imageUrl =
        '/api/v1/tips/images/00000000-0000-4000-8000-000000000001.png';
    await tester.pumpWidget(MaterialApp(
      home: ShuyoContentDetailPage(
        item: const ShuyoContentItem(
          id: 'tip_image',
          title: '带图提示',
          content: '![示意图]($imageUrl)',
          createdAt: null,
          updatedAt: null,
        ),
        kind: ShuyoContentKind.tips,
        baseUri: Uri(scheme: 'https', host: 'api.shuyo.work'),
      ),
    ));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, isA<ResizeImage>());
    expect(image.frameBuilder, isNotNull);
    final placeholder = find.byKey(shuyoTipImagePlaceholderKey);
    if (placeholder.evaluate().isNotEmpty) {
      expect(tester.getSize(placeholder).height, 180);
    } else {
      expect(find.text('图片加载失败'), findsOneWidget);
    }
    final imageTap = find
        .ancestor(
            of: find.byType(Image).first,
            matching: find.byType(GestureDetector))
        .first;
    await tester.tap(imageTap);
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenImagePage), findsOneWidget);
  });

  testWidgets('notice rows animate when scrolling down and back up',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode({
            'success': true,
            'data': [
              for (var index = 0; index < 12; index++)
                {
                  'id': 'tip_$index',
                  'title': '提示 $index',
                  'content': '正文预览 $index',
                },
            ],
          })),
          200,
        ));
    await tester.pumpWidget(MaterialApp(
      home: ShuyoContentPage(
        repository: ShuyoContentRepository(
          client: client,
          baseUrl: 'https://api.shuyo.work',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('提示 0'), findsOneWidget);
    final firstRipple = find
        .ancestor(
          of: find.text('提示 0'),
          matching: find.byType(InkWell),
        )
        .first;
    expect(tester.getRect(firstRipple).left, 0);
    expect(tester.getSize(firstRipple).width, 320);
    await tester.drag(find.byType(ListView).first, const Offset(0, -620));
    await tester.pump();
    final downRow = find.ancestor(
      of: find.text('提示 5'),
      matching: find.byType(SlideTransition),
    );
    expect(downRow, findsWidgets);
    expect(tester.widget<SlideTransition>(downRow.first).position.value.dx,
        greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.widget<SlideTransition>(downRow.first).position.value.dx, 0);
    await tester.drag(find.byType(ListView).first, const Offset(0, 620));
    await tester.pump();
    final upRow = find.ancestor(
      of: find.text('提示 0'),
      matching: find.byType(SlideTransition),
    );
    expect(upRow, findsWidgets);
    expect(tester.widget<SlideTransition>(upRow.first).position.value.dx,
        greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
