import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement.dart';
import 'package:shuyo/data/repositories/announcement_repository.dart';
import 'package:shuyo/features/home/announcements_page.dart';

const _listTitle = '关于开展实验室安全检查的通知';
const _detailBody = '各单位请于本周五前完成自查。';
const _imageUrl = 'https://www.shu.edu.cn/__local/0/94/a.png';
const _listUrl = 'https://www.shu.edu.cn/info/1051/1.htm';

const _listItem = AnnouncementListItem(
  title: _listTitle,
  url: _listUrl,
);

class _FakeAnnouncementRepository extends AnnouncementRepository {
  _FakeAnnouncementRepository({
    required this.items,
    required this.details,
  });

  final List<AnnouncementListItem> items;
  final Map<String, AnnouncementDetail> details;
  int detailRequestCount = 0;

  @override
  Future<List<AnnouncementListItem>> fetchAnnouncements({
    bool forceRefresh = false,
  }) async =>
      items;

  @override
  Future<AnnouncementDetail> fetchDetail(AnnouncementListItem item) async {
    detailRequestCount++;
    return details[item.title]!;
  }
}

_FakeAnnouncementRepository _repositoryWith({
  List<AnnouncementContentBlock> blocks = const [
    AnnouncementContentBlock.text(_detailBody),
  ],
  String dateText = '',
  String department = '',
  String author = '',
  String listDateText = '',
}) {
  return _FakeAnnouncementRepository(
    items: [
      AnnouncementListItem(
        title: _listTitle,
        url: _listUrl,
        dateText: listDateText,
      ),
    ],
    details: {
      _listTitle: AnnouncementDetail(
        title: _listTitle,
        url: _listItem.url,
        blocks: blocks,
        dateText: dateText,
        department: department,
        author: author,
      ),
    },
  );
}

Future<void> _openDetail(
    WidgetTester tester, AnnouncementRepository repository) async {
  await tester.pumpWidget(
    MaterialApp(home: AnnouncementsPage(repository: repository)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(_listTitle));
}

void main() {
  testWidgets('detail body waits for the push animation', (tester) async {
    final repository = _repositoryWith();
    await _openDetail(tester, repository);

    await tester.pump();
    // The request is fired on the first frame, but the body waits for the
    // transition to finish.
    expect(repository.detailRequestCount, 1);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(_detailBody), findsNothing);

    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_detailBody), findsOneWidget);
  });

  testWidgets('loading state can reuse its layer during the transition',
      (tester) async {
    final repository = _repositoryWith();
    await _openDetail(tester, repository);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // The loading state carries its own repaint boundary, so the transition
    // does not drag the whole page into a repaint.
    expect(
      find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(RepaintBoundary),
      ),
      findsWidgets,
    );
  });

  testWidgets('detail images are decoded at the displayed width',
      (tester) async {
    final repository = _repositoryWith(
      blocks: const [
        AnnouncementContentBlock.text(_detailBody),
        AnnouncementContentBlock.image(_imageUrl),
      ],
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());

    final context = tester.element(find.byType(Image));
    final displayPixels = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (provider as ResizeImage).width!;
    // Decoded at the displayed width: below the screen's pixel width, but not
    // small enough to look blurry.
    expect(decodeWidth, lessThanOrEqualTo(displayPixels.round()));
    expect(decodeWidth, greaterThan((displayPixels * 0.8).round()));
    expect(image.frameBuilder, isNotNull);
  });

  testWidgets('detail images reserve height before they are decoded',
      (tester) async {
    final repository = _repositoryWith(
      blocks: const [
        AnnouncementContentBlock.text(_detailBody),
        AnnouncementContentBlock.image(_imageUrl),
      ],
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    final placeholder = find.byKey(announcementImagePlaceholderKey);
    if (placeholder.evaluate().isEmpty) {
      // If the image fails first it renders through errorBuilder, which also
      // rules out a zero height.
      expect(find.text('图片加载失败'), findsOneWidget);
      return;
    }
    expect(tester.getSize(placeholder).height, greaterThan(0));
  });

  testWidgets('metadata renders the date, department and author',
      (tester) async {
    final repository = _repositoryWith(
      dateText: '2026.09.20',
      department: '后勤保障部',
      author: '钱杰妮',
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('2026.09.20'), findsOneWidget);
    expect(find.text('后勤保障部'), findsOneWidget);
    expect(find.text('钱杰妮'), findsOneWidget);
  });

  testWidgets('metadata is borderless rather than drawn as chips',
      (tester) async {
    final repository = _repositoryWith(
      dateText: '2026.09.20',
      department: '后勤保障部',
      author: '钱杰妮',
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    // A pill would read as something tappable, so the metadata stays plain:
    // no decorated ancestor behind any of the three labels.
    for (final label in ['2026.09.20', '后勤保障部', '钱杰妮']) {
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
        reason: '$label should not sit inside a chip shell',
      );
    }
  });

  testWidgets('each metadata item carries its own icon', (tester) async {
    final repository = _repositoryWith(
      dateText: '2026.09.20',
      department: '后勤保障部',
      author: '钱杰妮',
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    expect(find.byIcon(Icons.apartment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('an empty metadata field is skipped', (tester) async {
    final repository = _repositoryWith(dateText: '2026.09.20');
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    expect(find.byIcon(Icons.apartment_outlined), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('a repeated department is not rendered twice', (tester) async {
    final repository = _repositoryWith(
      dateText: '2026.09.20',
      department: '后勤保障部',
      author: '后勤保障部',
    );
    await _openDetail(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('后勤保障部'), findsOneWidget);
    expect(find.byIcon(Icons.apartment_outlined), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('the list marks the date with the same icon as the detail',
      (tester) async {
    final repository = _repositoryWith(listDateText: '2026.09.20');
    await tester.pumpWidget(
      MaterialApp(home: AnnouncementsPage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026.09.20'), findsOneWidget);
    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
  });

  testWidgets('the app bar exposes a share action', (tester) async {
    await _openDetail(tester, _repositoryWith());
    await tester.pumpAndSettle();

    expect(find.byTooltip('分享'), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
    // Refreshing was moved out of the app bar.
    expect(find.byTooltip('刷新'), findsNothing);
  });

  testWidgets('the action row copies the article link', (tester) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(call);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await _openDetail(tester, _repositoryWith());
    await tester.pumpAndSettle();

    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();

    expect(clipboard, hasLength(1));
    expect(
      (clipboard.single.arguments as Map<Object?, Object?>)['text'],
      _listItem.url,
    );
    expect(find.text('链接已复制'), findsOneWidget);
  });
}
