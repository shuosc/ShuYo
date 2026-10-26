import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/announcement.dart';
import '../models/announcement_source.dart';
import '../models/announcement_target.dart';

enum ListDateStrategy { text, secondTableCell, mbaParts, computerParts }

/// All DOM differences for a list template live together. A source chooses one
/// profile; extracting its links, text, dates and pagination follows one path.
class ListDomProfile {
  const ListDomProfile({
    required this.rows,
    required this.nextPage,
    this.root,
    this.anchor = 'a',
    this.title,
    this.titleWithinAnchor = false,
    this.date,
    this.summary,
    this.summaryWithinAnchor = false,
    this.trimTitleDate = false,
    this.allowRowDateFallback = true,
    this.onclickLink = false,
    this.acceptLoadMore = false,
    this.dateStrategy = ListDateStrategy.text,
  });

  final String? root;
  final String rows;
  final String anchor;
  final String? title;
  final bool titleWithinAnchor;
  final String? date;
  final String? summary;
  final bool summaryWithinAnchor;
  final String nextPage;
  final bool trimTitleDate;
  final bool allowRowDateFallback;
  final bool onclickLink;
  final bool acceptLoadMore;
  final ListDateStrategy dateStrategy;
}

abstract final class AnnouncementListParser {
  static const profiles = <AnnouncementListFormat, ListDomProfile>{
    AnnouncementListFormat.shuHome: ListDomProfile(
      root: '.ej_main .list',
      rows: 'ul > li > a',
      title: '.bt',
      date: '.sj',
      summary: '.zy',
      nextPage: 'span.p_pages a',
    ),
    AnnouncementListFormat.onlyList: ListDomProfile(
      root: 'div.only-list, div.only-list1',
      rows: 'li',
      nextPage: 'div.fanye a',
    ),
    AnnouncementListFormat.artList: ListDomProfile(
      rows: 'table.ArtList',
      anchor: 'a.linkfont1',
      title: 'a.linkfont1',
      date: 'span.linkfont1',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.vsbTable: ListDomProfile(
      rows: 'tr[id^="line_u"]',
      dateStrategy: ListDateStrategy.secondTableCell,
      nextPage: 'a.Next, span.p_next a',
    ),
    AnnouncementListFormat.centreList: ListDomProfile(
      root: 'div.list-centre-right-down',
      rows: 'li.clearfix',
      date: 'p.list-centre-right-down-p',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.rightList: ListDomProfile(
      root: 'div.right-list, div.list-right',
      rows: 'li',
      date: 'span',
      nextPage: 'div.right-list a, div.list-right a, a.Next',
    ),
    AnnouncementListFormat.rightListUl: ListDomProfile(
      root: 'ul.rightList',
      rows: 'li',
      date: 'span',
      trimTitleDate: true,
      nextPage: 'span.p_pages a, a.Next',
    ),
    AnnouncementListFormat.vsbNewList: ListDomProfile(
      rows: 'li[id^="line_u"]',
      date: 'i, span',
      trimTitleDate: true,
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.listPage: ListDomProfile(
      root: 'ul.listPage',
      rows: 'li',
      date: 'span',
      nextPage: 'span.p_pages a',
    ),
    AnnouncementListFormat.sjList: ListDomProfile(
      root: 'ul.sj-list-ul',
      rows: 'li[id^="line_u"]',
      date: 'p',
      trimTitleDate: true,
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.bareSpanList: ListDomProfile(
      rows: 'li[id^="line_u"]',
      date: 'span',
      trimTitleDate: true,
      nextPage: 'a.Next, span.p_pages a',
    ),
    AnnouncementListFormat.mbaList: ListDomProfile(
      root: 'ul.news-list',
      rows: 'li.news-item',
      title: 'div.news-title',
      dateStrategy: ListDateStrategy.mbaParts,
      onclickLink: true,
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.sjcList: ListDomProfile(
      root: 'div.jjyRight.fr',
      rows: 'li.clearfix',
      date: 'span.fr',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.nestedListUl: ListDomProfile(
      root: 'ul.listUL ul.listUL',
      rows: 'li',
      title: '.whitespace',
      date: '.day',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.xwLt: ListDomProfile(
      root: 'div.xw-lt, div.tzgg',
      rows: 'li',
      title: 'h3',
      dateStrategy: ListDateStrategy.computerParts,
      summary: '.xw-tx p, .tz-tx p',
      nextPage: 'span.p_pages a',
    ),
    AnnouncementListFormat.listPageList: ListDomProfile(
      root: 'ul.listPageList',
      rows: 'li',
      title: 'p',
      titleWithinAnchor: true,
      date: 'div',
      summary: 'span',
      summaryWithinAnchor: true,
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.listRLb: ListDomProfile(
      root: 'div.listR-lb',
      rows: 'li',
      date: 'i',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.filmNotice: ListDomProfile(
      rows: 'div.right li.notice-item',
      anchor: 'a.notice-title',
      summary: '.notice-content',
      allowRowDateFallback: false,
      nextPage: 'span.p_next a',
    ),
    AnnouncementListFormat.contentBoxList: ListDomProfile(
      root: 'div.content-box.fr.zsxx',
      rows: 'li[id^="line_u"]',
      allowRowDateFallback: false,
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.unorderedList: ListDomProfile(
      root: 'div.list.fl > ul',
      rows: 'li',
      date: 'span',
      nextPage: 'span.p_pages a',
    ),
    AnnouncementListFormat.shvfsNews: ListDomProfile(
      rows: 'ul.news-main-list > li.pr',
      anchor: 'div.news-go-more a[href]',
      title: 'div.news-item-info h2',
      date: 'div.news-item-info > span',
      summary: 'div.news-item-info > p',
      acceptLoadMore: true,
      nextPage: 'ul.yiiPager li.next a',
    ),
    AnnouncementListFormat.whitespaceList: ListDomProfile(
      root: 'ul.listUL',
      rows: 'li',
      title: '.whitespace',
      date: '.abstract',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.newsBodyList: ListDomProfile(
      root: '.news-body',
      rows: 'li',
      date: '.news-data',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.undergraduateAdmissions: ListDomProfile(
      root: '.list-rContent-down',
      rows: 'li[id^="line_u"]',
      date: 'i',
      nextPage: 'a.Next',
    ),
    AnnouncementListFormat.graduateAdmissions: ListDomProfile(
      rows: '.dec-listPage .list-right ul.clearfix > li.clearfix',
      title: 'h3',
      date: 'span',
      nextPage: '.dec-listPage span.p_next a',
    ),
  };

  static ListDomProfile profileFor(AnnouncementSource source) =>
      profiles[source.adapter.listFormat]!;

  static List<AnnouncementListItem> parse(
    String html, {
    required String baseUrl,
    AnnouncementSource source = AnnouncementSource.official,
    String column = '',
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final profile = profileFor(source);
    final root =
        profile.root == null ? document : document.querySelector(profile.root!);
    final rows = root?.querySelectorAll(profile.rows) ?? const <dom.Element>[];
    final items = <AnnouncementListItem>[];
    for (final row in rows) {
      final anchor =
          row.localName == 'a' ? row : row.querySelector(profile.anchor);
      if (anchor == null && !profile.onclickLink) continue;
      final titleRoot = profile.titleWithinAnchor ? anchor : row;
      var title = _clean(profile.title == null
          ? anchor?.text
          : titleRoot?.querySelector(profile.title!)?.text);
      final rawDate = _dateText(row, profile);
      if (profile.trimTitleDate &&
          rawDate.isNotEmpty &&
          title.endsWith(rawDate)) {
        title = title.substring(0, title.length - rawDate.length).trim();
      }
      final href = profile.onclickLink
          ? _onclickUrl.firstMatch(row.attributes['onclick'] ?? '')?.group(1) ??
              ''
          : anchor?.attributes['href'] ?? '';
      final url = resolveAnnouncementUrl(baseUrl, href);
      if (title.isEmpty || url.isEmpty) continue;
      final publishedAt = _parseDate(rawDate.isNotEmpty
          ? rawDate
          : profile.allowRowDateFallback
              ? row.text
              : '');
      final summaryRoot = profile.summaryWithinAnchor ? anchor : row;
      items.add(AnnouncementListItem(
        title: title,
        url: url,
        summary: profile.summary == null
            ? ''
            : _clean(summaryRoot?.querySelector(profile.summary!)?.text),
        dateText: publishedAt == null
            ? rawDate
            : '${publishedAt.year.toString().padLeft(4, '0')}-'
                '${publishedAt.month.toString().padLeft(2, '0')}-'
                '${publishedAt.day.toString().padLeft(2, '0')}',
        publishedAt: publishedAt,
        sourceId: source.id,
        column: column,
      ));
    }
    return items;
  }

  static String? nextPageUrl(
    String html, {
    required String baseUrl,
    required AnnouncementSource source,
    dom.Document? parsedDocument,
  }) {
    final document = parsedDocument ?? html_parser.parse(html);
    final profile = profileFor(source);
    for (final link in document.querySelectorAll(profile.nextPage)) {
      final label = _clean(link.text);
      if (label != '下页' &&
          label != '下一页' &&
          !(profile.acceptLoadMore && label == '加载更多')) {
        continue;
      }
      final next =
          resolveAnnouncementUrl(baseUrl, link.attributes['href'] ?? '');
      if (next.isNotEmpty &&
          next != baseUrl &&
          Uri.parse(next).host == Uri.parse(source.listUrl).host) {
        return next;
      }
    }
    return null;
  }

  static final _onclickUrl = RegExp(r'''window\.open\(["']([^"']+)["']''');

  static String _dateText(dom.Element row, ListDomProfile profile) {
    switch (profile.dateStrategy) {
      case ListDateStrategy.text:
        return profile.date == null
            ? ''
            : _clean(row.querySelector(profile.date!)?.text);
      case ListDateStrategy.secondTableCell:
        final cells = row.querySelectorAll('td');
        return cells.length > 1 ? _clean(cells[1].text) : '';
      case ListDateStrategy.mbaParts:
        final day = _clean(row.querySelector('.date-day')?.text);
        final yearMonth = _clean(row.querySelector('.date-ym')?.text);
        return day.isNotEmpty && yearMonth.isNotEmpty
            ? '$yearMonth-$day'
            : _clean(row.querySelector('div.date-box')?.text);
      case ListDateStrategy.computerParts:
        final box = row.querySelector('.xw-date, .tz-d');
        final day = _clean(box?.querySelector('b')?.text);
        final yearMonth = _clean(box?.querySelector('span')?.text);
        return day.isNotEmpty && yearMonth.isNotEmpty
            ? '$yearMonth-$day'
            : _clean(box?.text);
    }
  }

  static DateTime? _parseDate(String value) {
    final match =
        RegExp(r'(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})').firstMatch(value);
    return match == null
        ? null
        : DateTime(
            int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  static String _clean(String? value) => (value ?? '')
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
