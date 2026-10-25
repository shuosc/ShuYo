import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/announcement_api_client.dart';

void main() {
  // These pages share the same VSB metadata table, including an author span
  // without an author label. Keep the source IDs so this covers template
  // detection rather than a list of source-specific exceptions.
  const samples = [
    (
      sourceId: 'mkszyxy',
      articlePath: '1129/81904',
      title: '上海大学2026年青年学者论坛 马克思主义学院专场',
      author: '赵雪燕',
      date: '2026/10/08',
    ),
    (
      sourceId: 'bio',
      articlePath: '1145/74658',
      title: '【推免招生信息】上海大学生命科学学院2027年接收推荐免试攻读研究生(含直博生)预报名通知',
      author: '董海燕',
      date: '2026/09/08',
    ),
    (
      sourceId: 'ulisboas',
      articlePath: '1049/2442',
      title: '上海大学与里斯本大学合办外国硕士项目常见问题',
      author: '胡鑫源',
      date: '2025/03/06',
    ),
    (
      sourceId: 'zhgy',
      articlePath: '1021/3081',
      title: '上海大学卓越工程师学院2026年研究生创新实践项目立项通知',
      author: '任一凡',
      date: '2026/10/14',
    ),
    (
      sourceId: 'soe',
      articlePath: '1192/47934',
      title: '【研究生】经济学院2027年接受推荐免试攻读硕士研究生（含直博生）复试工作方案',
      author: '杨轶',
      date: '2026/09/16',
    ),
    (
      sourceId: 'silc',
      articlePath: '1035/100483',
      title: '2026年悉尼工商学院“格致”奖学金评选结果公示',
      author: '周羽',
      date: '2026/10/21',
    ),
    (
      sourceId: 'ihe',
      articlePath: '1021/1741',
      title: '关于做好我校2026年度上海市哲学社会科学规划项目申报工作的通知',
      author: '吕明霞',
      date: '2026/10/19',
    ),
    (
      sourceId: 'icn',
      articlePath: '1541/2621',
      title: '澳大利亚昆士兰大学余承忠教授访问碳中和创新研究中心并作学术报告',
      author: '茅润芳',
      date: '2026/09/24',
    ),
    (
      sourceId: 'skl4nm',
      articlePath: '1031/2081',
      title: '2026年核电关键材料全国重点实验室兴邦奖学金获奖名单公示',
      author: '张夏聪',
      date: '2026/10/12',
    ),
    (
      sourceId: 'sklar',
      articlePath: '1502/1952',
      title: '先进耐火材料全国重点实验室（上海）2025年开放课题拟立项项目公示',
      author: '高雅',
      date: '2026/01/04',
    ),
  ];

  for (final sample in samples) {
    test('VSB metadata table parses ${sample.sourceId} article author', () {
      final detail = AnnouncementApiClient.parseAnnouncementDetail(
        '''
<div class="content">
  <div>
    <table width="100%" cellspacing="0" cellpadding="0" border="0">
      <tbody><tr valign="top"><td align="center">
        <table cellspacing="0" cellpadding="0" align="center">
          <tbody>
            <tr><td colspan="2" align="center">
              <span class="Head" style="color:#000;font-weight:bold;font-size:20px;">${sample.title}</span>
            </td></tr>
            <tr valign="middle" height="20" align="center">
              <td>
                <span style="color:#666;font-size:13px;font-weight:bold;">创建时间：&nbsp;&nbsp;</span><span style="color:#666;font-size:13px;">${sample.date}</span>&nbsp;<font face="">
                  <span style="color:#666;font-size:13px;">${sample.author}</span>&nbsp;<font face="Times New Roman">&nbsp;
                    <span style="color:#666;font-size:13px;font-weight:bold;">浏览次数：</span>
                  </font>
                  <span style="color:#666;font-size:13px;"><script>_showDynClicks("wbnews", 12345, 67890)</script></span>
                </font>
              </td>
            </tr>
          </tbody>
        </table>
      </td></tr></tbody>
    </table>
    <table width="100%" cellspacing="0" cellpadding="0">
      <tbody><tr><td>
        <div id="vsb_content_4"><div class="v_news_content"><p>公告正文</p></div></div>
      </td></tr></tbody>
    </table>
  </div>
</div>
''',
        url:
            'https://${sample.sourceId}.shu.edu.cn/info/${sample.articlePath}.htm',
        sourceId: sample.sourceId,
        fallbackTitle: '列表中的备用标题',
        fallbackDateText: '1999-01-01',
        fallbackPublishedAt: DateTime(1999),
      );

      final expectedDate = sample.date.replaceAll('/', '-');
      expect(detail.title, sample.title);
      expect(detail.author, sample.author);
      expect(detail.dateText, expectedDate);
      expect(detail.publishedAt, DateTime.parse(expectedDate));
      expect(detail.blocks.single.value, '公告正文');
    });
  }

  for (final bodyLabel in ['报名时间', '创建时间']) {
    test('body table labelled $bodyLabel does not supply article metadata', () {
      final detail = AnnouncementApiClient.parseAnnouncementDetail(
        '''
<div class="nry">
  <h1>普通公告</h1>
  <div class="xx"><span>发布时间：2026-10-26</span></div>
  <div class="v_news_content">
    <table><tbody>
      <tr><td><span class="Head">活动安排</span></td></tr>
      <tr valign="middle"><td>
        <span>$bodyLabel：</span><span>2026/10/27</span>
        <font face=""><span>报名联系人</span></font>
      </td></tr>
    </tbody></table>
    <p><font face=""><span>正文中的人名</span></font></p>
  </div>
</div>
''',
        url: 'https://mkszyxy.shu.edu.cn/info/1129/example.htm',
        sourceId: 'mkszyxy',
      );

      expect(detail.title, '普通公告');
      expect(detail.author, isEmpty);
      expect(detail.dateText, '2026-10-26');
    });
  }
}
