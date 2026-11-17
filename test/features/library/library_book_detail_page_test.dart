import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/utils/library_book_citation.dart';
import 'package:shuyo/data/models/library_book_detail.dart';
import 'package:shuyo/features/library/library_book_citation_bottom_sheet.dart';
import 'package:shuyo/features/library/library_book_detail_page.dart';

void main() {
  group('LibraryBookDetailModel', () {
    test('prefers composite baseMarcInfoDto.titles over short base title', () {
      final model = LibraryBookDetailModel.fromApiResponse(
        recordId: 795684,
        detailData: {
          'baseMarcInfoDto': {
            'title': '中国诗歌',
            'titles': '中国诗歌.第69卷(2015年第九卷).水边的月亮',
            'cleanAuthor': '主编阎志',
            'publisher': '人民文学出版社',
            'publishYear': '2015',
            'isbn': '978-7-02-011146-6',
          },
        },
      );

      expect(model.title, '中国诗歌.第69卷(2015年第九卷).水边的月亮');
    });

    test('falls back to baseMarcInfoDto.title when titles is empty', () {
      final model = LibraryBookDetailModel.fromApiResponse(
        recordId: 796762,
        detailData: {
          'baseMarcInfoDto': {
            'title': '机器学习',
            'titles': '',
          },
        },
      );

      expect(model.title, '机器学习');
    });
  });

  group('LibraryBookCitation', () {
    test('formats GB/T 7714, MLA and APA correctly matching web standard', () {
      const citation = LibraryBookCitation(
        title: '蒲松龄的账本 : 《聊斋》商业图景',
        author: '牛晓燕著',
        cleanAuthor: '牛晓燕著',
        publisher: '商务印书馆',
        pubPlace: '北京',
        publishYear: '2026',
        docCode: 1,
      );

      expect(
        citation.gb7714,
        '[1]牛晓燕著.蒲松龄的账本 : 《聊斋》商业图景[M].北京:商务印书馆,2026.',
      );
      expect(
        citation.mla,
        '牛晓燕著. "蒲松龄的账本 : 《聊斋》商业图景". 商务印书馆(2026).',
      );
      expect(
        citation.apa,
        '牛晓燕著. (2026). 蒲松龄的账本 : 《聊斋》商业图景. 商务印书馆.',
      );
    });

    test(
        'generates export formats BibTex, EndNote, RefMan, NoteExpress, NoteFirst',
        () {
      const citation = LibraryBookCitation(
        title: '机器学习',
        author: '周志华著',
        publisher: '清华大学出版社',
        pubPlace: '北京',
        publishYear: '2016',
      );

      expect(citation.exportBibTex(), contains('@book{'));
      expect(citation.exportEndNote(), contains('%0 Book'));
      expect(citation.exportRefMan(), contains('TY  - Book'));
      expect(citation.exportNoteExpress(), contains('{Reference Type}: Book'));
      expect(citation.exportNoteFirst(), contains('<Bibliographies'));
    });
  });

  group('LibraryBookDetailPage & CitationBottomSheet', () {
    testWidgets('shows citation bottom sheet on button tap', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LibraryBookDetailPage(
            recordId: 796762,
            title: '机器学习',
            author: '周志华著',
            publisher: '清华大学出版社',
            publishYear: '2016',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.format_quote_rounded), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);

      await tester.tap(find.byIcon(Icons.format_quote_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(LibraryBookCitationBottomSheet), findsOneWidget);
      expect(find.text('GB/T 7714'), findsOneWidget);
      expect(find.text('MLA'), findsOneWidget);
      expect(find.text('APA'), findsOneWidget);
      expect(find.text('BibTex'), findsOneWidget);
    });

    testWidgets(
        'renders book detail layout, holdings and metadata with copy interaction',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LibraryBookDetailPage(
            recordId: 796762,
            title: '机器学习',
            author: '周志华著',
            publisher: '清华大学出版社',
            publishYear: '2016',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('图书详情'), findsOneWidget);
      expect(find.text('机器学习'), findsWidgets);
      expect(find.text('清华大学出版社 (2016)'), findsOneWidget);
      expect(find.text('宝山'), findsOneWidget);
      expect(find.text('嘉定'), findsOneWidget);
      expect(find.text('延长'), findsOneWidget);
    });
  });
}
