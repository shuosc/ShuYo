import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/announcement_target.dart';

void main() {
  test(
      'actual hosts select article ownership and only the official site shows departments',
      () {
    for (final sample in [
      (
        url: 'https://shu.edu.cn/info/1051/402205.htm',
        listedFrom: 'sfa',
        owner: 'shu',
        kind: AnnouncementArticleKind.vsb,
        department: true
      ),
      (
        url: 'https://www.shu.edu.cn/info/1051/402205.htm',
        listedFrom: 'bkzsw',
        owner: 'shu',
        kind: AnnouncementArticleKind.vsb,
        department: true
      ),
      (
        url: 'https://BKZSW.SHU.EDU.CN/info/1798/38490.htm',
        listedFrom: 'sfa',
        owner: 'bkzsw',
        kind: AnnouncementArticleKind.vsb,
        department: false
      ),
      (
        url: 'https://www.scie.shu.edu.cn/info/1022/1.htm',
        listedFrom: 'xiangying',
        owner: 'scie',
        kind: AnnouncementArticleKind.vsb,
        department: false
      ),
      (
        url: 'https://shvfs.cn/site/newsDetail/1624',
        listedFrom: 'sfa',
        owner: 'shvfs',
        kind: AnnouncementArticleKind.vancouver,
        department: false
      ),
      (
        url: 'https://www.shvfs.cn/site/newsDetail/1624',
        listedFrom: 'shu',
        owner: 'shvfs',
        kind: AnnouncementArticleKind.vancouver,
        department: false
      ),
      (
        url: 'https://future-department.shu.edu.cn/info/1010/1.htm',
        listedFrom: 'shu',
        owner: null,
        kind: AnnouncementArticleKind.vsb,
        department: false
      ),
    ]) {
      final target =
          AnnouncementTarget.resolve(sample.url, sourceId: sample.listedFrom);
      expect(target.owner?.id, sample.owner, reason: sample.url);
      expect(target.kind, sample.kind, reason: sample.url);
      expect(target.canOpenInApp, isTrue, reason: sample.url);
      expect(target.canLoadMetadata, isTrue, reason: sample.url);
      expect(target.canPreview, isTrue, reason: sample.url);
      expect(target.showDepartment, sample.department, reason: sample.url);
    }
  });

  test('preview capability excludes static resources and non-web addresses',
      () {
    for (final url in [
      'https://www.shu.edu.cn/notice.PDF?download=1#page=3',
      'https://bkzsw.shu.edu.cn/guide.docx',
      'https://www.shvfs.cn/photo.jpg',
      'https://www.shu.edu.cn/archive.zip',
      'file:///C:/notice.htm',
      'javascript:alert(1)',
      'mailto:office@shu.edu.cn',
      'ftp://www.shu.edu.cn/info/1051/1.htm',
      '/info/1051/1.htm',
    ]) {
      final target = AnnouncementTarget.resolve(url, sourceId: 'shu');
      expect(target.canPreview, isFalse, reason: url);
      expect(target.canLoadMetadata, isFalse, reason: url);
      expect(target.canOpenInApp, isFalse, reason: url);
      expect(target.showDepartment, isFalse, reason: url);
    }
    final external =
        AnnouncementTarget.resolve('https://example.org/article?id=1');
    expect(external.canPreview, isTrue);
    expect(external.canLoadMetadata, isFalse);
    expect(external.canOpenInApp, isFalse);
  });

  test(
      'article identity drops fragments, preserves queries and resolves only web links',
      () {
    expect(
        announcementUrlKey(
            ' https://shu.edu.cn/info/1051/1.htm?lang=en#heading '),
        'https://shu.edu.cn/info/1051/1.htm?lang=en');
    expect(
        announcementUrlKey(
            'https://shu.edu.cn/info/1051/1.htm?lang=zh#heading'),
        isNot(announcementUrlKey(
            'https://shu.edu.cn/info/1051/1.htm?lang=en#other')));
    expect(
        resolveAnnouncementUrl('https://shu.edu.cn/news/list.htm',
            '../info/1051/1.htm?lang=en#body'),
        'https://shu.edu.cn/info/1051/1.htm?lang=en#body');
    for (final value in [
      '',
      'javascript:void(0)',
      'mailto:a@shu.edu.cn',
      'data:text/html,x'
    ]) {
      expect(resolveAnnouncementUrl('https://shu.edu.cn/news.htm', value),
          isEmpty);
    }
  });
}
