enum AnnouncementListFormat {
  shuHome,
  onlyList,
  artList,
  vsbTable,
  centreList,
  rightList,
  rightListUl,
  vsbNewList,
  listPage,
  sjList,
  bareSpanList,
  mbaList,
  sjcList,
  nestedListUl,
  xwLt,
  listPageList,
  listRLb,
  filmNotice,
  contentBoxList,
  unorderedList,
  shvfsNews,
  whitespaceList,
  newsBodyList,
  undergraduateAdmissions,
  graduateAdmissions,
}

enum AnnouncementCollegeCategory {
  humanitiesSocial('人文社科类', [
    'mkszyxy',
    'sfs',
    'sociology',
    'schim',
    'cla',
    'law',
    'sjc',
  ]),
  engineeringScience('理工类', [
    'qwc',
    'scie',
    'xiangying',
    'auto',
    'ece',
    'utseus',
    'smes',
    'ai',
    'scicol',
    'cs',
    'mat',
    'bio',
    'sme',
    'ulisboas',
    'zhgy',
  ]),
  economicsManagement('经济管理类', ['soe', 'silc', 'ms']),
  medicine('医学类', ['medicine']),
  arts('艺术类', ['safa', 'music', 'sfa', 'shvfs']),
  other('其他类', ['tiyu', 'cce', 'cie', 'mba', 'modart']);

  const AnnouncementCollegeCategory(this.label, this.sourceIds);

  final String label;
  final List<String> sourceIds;
}

enum AnnouncementSourceGroup {
  schoolPortal('学校门户'),
  administrativeDepartment('行政部门'),
  affiliatedInstitution('直属机构'),
  college('学院'),
  researchInstitute('研究院所');

  const AnnouncementSourceGroup(this.label);

  final String label;
}

class AnnouncementSourceAdapter {
  const AnnouncementSourceAdapter({
    required this.listFormat,
    this.hideListColumn = false,
  });

  final AnnouncementListFormat listFormat;
  final bool hideListColumn;
}

class AnnouncementSource {
  const AnnouncementSource({
    required this.id,
    required this.name,
    required this.listUrl,
    required this.adapter,
    this.searchOwner,
    this.searchColumnIds = const [],
    this.additionalListUrls = const [],
    this.columnNames = const [],
    this.group = AnnouncementSourceGroup.administrativeDepartment,
  });

  final String id;
  final String name;
  final String listUrl;
  final AnnouncementSourceAdapter adapter;

  /// Current site owner in the public VSB search index.
  ///
  /// Null means the source is not supported by website-group search.
  final String? searchOwner;

  /// Explicit VSB columns corresponding to the configured notification lists.
  /// Includes aggregate lists and the article columns they currently display.
  final List<String> searchColumnIds;

  bool get supportsSearch =>
      searchOwner != null &&
      searchOwner!.isNotEmpty &&
      searchColumnIds.isNotEmpty;
  AnnouncementListFormat get format => adapter.listFormat;
  final List<String> additionalListUrls;
  final List<String> columnNames;
  final AnnouncementSourceGroup group;

  List<String> get listUrls => [listUrl, ...additionalListUrls];

  static const officialId = 'shu';

  static const official = AnnouncementSource(
    id: officialId,
    searchOwner: '1864855249',
    searchColumnIds: ['1051'],
    name: '上海大学官网',
    listUrl: 'https://www.shu.edu.cn/tzgg.htm',
    adapter: AnnouncementSourceAdapter(
      listFormat: AnnouncementListFormat.shuHome,
    ),
    group: AnnouncementSourceGroup.schoolPortal,
  );

  static const all = <AnnouncementSource>[
    official,
    AnnouncementSource(
      id: 'bksy',
      searchOwner: '1662210750',
      searchColumnIds: ['1015'],
      name: '本科生院',
      listUrl: 'https://bksy.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    ),
    AnnouncementSource(
      id: 'bkzsw',
      searchOwner: '1364902694',
      searchColumnIds: [
        '1798',
        '1810',
        '7743',
        '7563',
        '7373',
        '7161',
        '2175',
        '1812',
        '1826',
        '7753',
        '7573',
        '7383',
        '7171',
        '2168',
        '1839',
        '7763',
        '7583',
        '7393',
        '7201',
        '2176',
        '1846',
        '7773',
        '7593',
        '7403',
        '7211',
        '2169',
        '1878',
        '7603',
        '7413',
        '7262',
        '2171',
        '7783',
        '1880',
        '1928',
        '7823',
        '7643',
        '7453',
        '7251',
        '2174',
        '1893',
        '7793',
        '7613',
        '7423',
        '7272',
        '2172',
        '1906',
        '7623',
        '7433',
        '7241',
        '2177',
        '7803',
        '1912',
        '1915',
        '7813',
        '7633',
        '7443',
        '7151',
        '2173',
      ],
      name: '本科生招生网',
      listUrl: 'https://bkzsw.shu.edu.cn/zxgg.htm',
      additionalListUrls: [
        'https://bkzsw.shu.edu.cn/zsjz/qjtk.htm',
        'https://bkzsw.shu.edu.cn/zsjz/cjzs.htm',
        'https://bkzsw.shu.edu.cn/zsjz/zhpjlq.htm',
        'https://bkzsw.shu.edu.cn/zsjz/ysl.htm',
        'https://bkzsw.shu.edu.cn/zsjz/bss.htm',
        'https://bkzsw.shu.edu.cn/zsjz/cbs.htm',
        'https://bkzsw.shu.edu.cn/zsjz/exw.htm',
        'https://bkzsw.shu.edu.cn/zsjz/gxzxjh.htm',
        'https://bkzsw.shu.edu.cn/zsjz/gatzha.htm',
      ],
      columnNames: [
        '最新公告',
        '秋季统考',
        '春季招生',
        '综合评价录取',
        '艺术类',
        '保送生',
        '插班生',
        '二学位',
        '高校专项计划',
        '港澳台招生',
      ],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.undergraduateAdmissions,
      ),
      group: AnnouncementSourceGroup.schoolPortal,
    ),
    AnnouncementSource(
      id: 'yjszs',
      searchOwner: '1462468299',
      searchColumnIds: ['1003', '1004'],
      name: '研究生招生网',
      listUrl: 'https://yjszs.shu.edu.cn/cd/tzgg.htm',
      additionalListUrls: ['https://yjszs.shu.edu.cn/cd/zsdt.htm'],
      columnNames: ['通知公告', '招生动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.graduateAdmissions,
      ),
      group: AnnouncementSourceGroup.schoolPortal,
    ),
    AnnouncementSource(
      id: 'yingxin',
      searchOwner: '1565422366',
      searchColumnIds: ['1008', '1007'],
      name: '迎新网',
      listUrl: 'https://yingxin.shu.edu.cn/tzgg.htm',
      additionalListUrls: ['https://yingxin.shu.edu.cn/rxxz.htm'],
      columnNames: ['通知公告', '入学须知'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
      ),
      group: AnnouncementSourceGroup.schoolPortal,
    ),
    AnnouncementSource(
      id: 'xgb',
      searchOwner: '1495423387',
      searchColumnIds: ['1003'],
      name: '本科生工作处',
      listUrl: 'https://xgb.shu.edu.cn/xgdt/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.artList,
      ),
    ),
    AnnouncementSource(
      id: 'dwygb',
      searchOwner: '1597130582',
      searchColumnIds: ['1050'],
      name: '研究生工作处',
      listUrl: 'https://dwygb.shu.edu.cn/xwzx/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
    ),
    AnnouncementSource(
      id: 'gs',
      searchOwner: '1880701254',
      searchColumnIds: ['1029', '1027', '1030', '1031'],
      name: '研究生院',
      listUrl: 'https://gs.shu.edu.cn/xwlb/py.htm',
      additionalListUrls: [
        'https://gs.shu.edu.cn/xwlb/zh.htm',
        'https://gs.shu.edu.cn/xwlb/gjjl.htm',
        'https://gs.shu.edu.cn/xwlb/xw.htm',
      ],
      columnNames: ['培养', '综合', '国际交流', '学位'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbTable,
        hideListColumn: true,
      ),
    ),
    AnnouncementSource(
      id: 'cwc',
      searchOwner: '1393148177',
      searchColumnIds: ['1015', '1041'],
      name: '财务处',
      listUrl: 'https://cwc.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.centreList),
    ),
    AnnouncementSource(
      id: 'lib',
      searchOwner: '1705785581',
      searchColumnIds: ['1022', '1023'],
      name: '图书馆',
      listUrl: 'https://lib.shu.edu.cn/sho/ggxx.htm',
      additionalListUrls: ['https://lib.shu.edu.cn/sho/zydt.htm'],
      columnNames: ['通知公告', '资源动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.affiliatedInstitution,
    ),
    AnnouncementSource(
      id: 'alumni',
      searchOwner: '1551701726',
      searchColumnIds: ['1021'],
      name: '对外联络处',
      listUrl: 'https://alumni.shu.edu.cn/xwggzx/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'shuedf',
      searchOwner: '1812157458',
      searchColumnIds: ['1005'],
      name: '上海大学教育发展基金会',
      listUrl: 'https://shuedf.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.affiliatedInstitution,
    ),
    AnnouncementSource(
      id: 'kyglb',
      searchOwner: '1425312184',
      searchColumnIds: ['1011'],
      name: '科研管理部',
      listUrl: 'https://kyglb.shu.edu.cn/dhl/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.unorderedList),
    ),
    AnnouncementSource(
      id: 'ac',
      searchOwner: '1602564467',
      searchColumnIds: ['1009', '1010'],
      name: '学术委员会',
      listUrl: 'https://ac.shu.edu.cn/synr/tzfw.htm',
      additionalListUrls: ['https://ac.shu.edu.cn/synr/sdxs.htm'],
      columnNames: ['通知发文', '上大学术'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
      ),
    ),
    AnnouncementSource(
      id: 'baoweichu',
      searchOwner: '1623616573',
      searchColumnIds: ['1061'],
      name: '保卫处',
      listUrl: 'https://baoweichu.shu.edu.cn/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    ),
    AnnouncementSource(
      id: 'its',
      searchOwner: '1663284523',
      searchColumnIds: ['1095'],
      name: '信息化工作办公室',
      listUrl: 'https://newits.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.onlyList,
      ),
    ),
    AnnouncementSource(
      id: 'youth',
      searchOwner: '1659861027',
      searchColumnIds: ['1010'],
      name: '上海大学共青团委员会',
      listUrl: 'https://youth.shu.edu.cn/syxzlly/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
    ),
    AnnouncementSource(
      id: 'global',
      searchOwner: '1479802255',
      searchColumnIds: ['1003'],
      name: '国际部',
      listUrl: 'https://global.shu.edu.cn/cd/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
      ),
    ),
    AnnouncementSource(
      id: 'hbb',
      searchOwner: '1675169118',
      searchColumnIds: ['1005'],
      name: '后勤保障部',
      listUrl: 'https://hbb.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'xyy',
      searchOwner: '1678802850',
      searchColumnIds: ['1090'],
      name: '校医院',
      listUrl: 'https://xyy.shu.edu.cn/sylm/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
      group: AnnouncementSourceGroup.affiliatedInstitution,
    ),
    AnnouncementSource(
      id: 'archive',
      searchOwner: '1663770242',
      searchColumnIds: ['1013'],
      name: '档案馆',
      listUrl: 'https://dangan.shu.edu.cn/gqgk/xxfb/fwgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
      ),
      group: AnnouncementSourceGroup.affiliatedInstitution,
    ),
    AnnouncementSource(
      id: 'sbc',
      searchOwner: '1530700580',
      searchColumnIds: ['1004'],
      name: '实验室与设备管理处',
      listUrl: 'https://sbc.shu.edu.cn/tg/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'hr',
      searchOwner: '1598626614',
      searchColumnIds: ['1029'],
      name: '人事处',
      listUrl: 'https://hr.shu.edu.cn/xwgg1/xwgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
    ),
    AnnouncementSource(
      id: 'cie',
      searchOwner: '1504253137',
      searchColumnIds: ['1014'],
      name: '国际教育学院',
      listUrl: 'https://cie.shu.edu.cn/tg/xytz.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.listPage),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cla',
      searchOwner: '1500565633',
      searchColumnIds: ['1017', '1015', '1019', '1020'],
      name: '文学院',
      listUrl: 'https://cla.shu.edu.cn/tg/tzgg.htm',
      additionalListUrls: [
        'https://cla.shu.edu.cn/tg/zhxw.htm',
        'https://cla.shu.edu.cn/tg/kydt.htm',
        'https://cla.shu.edu.cn/tg/xshd.htm',
      ],
      columnNames: ['通知公告', '信息动态', '科研动态', '学生活动'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.sjList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ece',
      searchOwner: '1880699954',
      searchColumnIds: ['1303', '1304', '1147', '1148'],
      name: '环境与化学工程学院',
      listUrl: 'https://ece.shu.edu.cn/sylm/bksjx.htm',
      additionalListUrls: [
        'https://ece.shu.edu.cn/sylm/yjsjx.htm',
        'https://ece.shu.edu.cn/sylm/tzgg.htm',
        'https://ece.shu.edu.cn/sylm/kydt1.htm',
      ],
      columnNames: ['本科生教学', '研究生教学', '通知公告', '科研动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightListUl,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mat',
      searchOwner: '1449189309',
      searchColumnIds: ['1018', '1019', '1013'],
      name: '材料科学与工程学院',
      listUrl: 'https://mat.shu.edu.cn/sycdlm/tzgg/bks.htm',
      additionalListUrls: [
        'https://mat.shu.edu.cn/sycdlm/tzgg/yjs.htm',
        'https://mat.shu.edu.cn/sycdlm/tzgg.htm',
      ],
      columnNames: ['通知公告(本科生)', '通知公告(研究生)', '通知公告'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightListUl,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mba',
      searchOwner: '1797966698',
      searchColumnIds: ['1024'],
      name: 'MBA教育管理中心',
      listUrl: 'https://mba.shu.edu.cn/cslm/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.mbaList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mgi',
      searchOwner: '1650566287',
      searchColumnIds: ['1062'],
      name: '材料基因组工程研究院',
      listUrl: 'https://mgi.shu.edu.cn/index/lmzl/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'suitm',
      searchOwner: '1771177353',
      searchColumnIds: ['1082', '1085', '1086'],
      name: '转化医学研究院',
      listUrl: 'https://suitm.shu.edu.cn/syzl/xwdt.htm',
      additionalListUrls: [
        'https://suitm.shu.edu.cn/tzgg.htm',
        'https://suitm.shu.edu.cn/kycg.htm',
      ],
      columnNames: ['新闻动态', '通知公告', '科研成果'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.whitespaceList,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'adri',
      searchOwner: '1691313259',
      searchColumnIds: ['1057'],
      name: '亚洲人口研究中心',
      listUrl: 'https://adrichn.shu.edu.cn/sylmnr/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'cast',
      searchOwner: '1676522650',
      searchColumnIds: ['1042', '1043', '1044'],
      name: '先进凝固技术中心',
      listUrl: 'https://cast.shu.edu.cn/sylm/xwkd.htm',
      additionalListUrls: [
        'https://cast.shu.edu.cn/sylm/yjcg.htm',
        'https://cast.shu.edu.cn/sylm/xsdt.htm',
      ],
      columnNames: ['新闻快递', '研究成果', '学术动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'icn',
      searchOwner: '2052219376',
      searchColumnIds: ['1531', '1541'],
      name: '碳中和创新研究中心',
      listUrl: 'https://icn.shu.edu.cn/index/kydt.htm',
      additionalListUrls: ['https://icn.shu.edu.cn/index/xwdt.htm'],
      columnNames: ['科研动态', '新闻动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.whitespaceList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'igs',
      searchOwner: '1471238366',
      searchColumnIds: ['1011', '1012'],
      name: '全球问题研究院',
      listUrl: 'https://igs.shu.edu.cn/cd/tzgg.htm',
      additionalListUrls: ['https://igs.shu.edu.cn/cd/xwzx.htm'],
      columnNames: ['通知公告', '新闻中心'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.newsBodyList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'ihe',
      searchOwner: '2063254418',
      searchColumnIds: ['1021'],
      name: '高等教育研究所',
      listUrl: 'https://ihe.shu.edu.cn/sybk/gjdt.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'jgzx',
      searchOwner: '1649809844',
      searchColumnIds: ['1017', '1019'],
      name: '上海经济管理中心',
      listUrl: 'https://jgzx.shu.edu.cn/synr/ywsd.htm',
      additionalListUrls: ['https://jgzx.shu.edu.cn/synr/zsjz.htm'],
      columnNames: ['要闻速递', '招生简章'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'jhai',
      searchOwner: '1730694740',
      searchColumnIds: ['1042'],
      name: '无人艇工程研究院',
      listUrl: 'https://jhai.shu.edu.cn/sylm/xwdt.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'museum',
      searchOwner: '1880701068',
      searchColumnIds: ['1030'],
      name: '博物馆',
      listUrl: 'https://museum.shu.edu.cn/bggk/xwkd.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
      group: AnnouncementSourceGroup.affiliatedInstitution,
    ),
    AnnouncementSource(
      id: 'suns',
      searchOwner: '1678865198',
      searchColumnIds: ['1020', '1019'],
      name: '数据科学与都市研究中心',
      listUrl: 'https://suns.shu.edu.cn/sy/gg.htm',
      additionalListUrls: ['https://suns.shu.edu.cn/sy/xw.htm'],
      columnNames: ['公告', '新闻'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'skl4nm',
      searchOwner: '2132341510',
      searchColumnIds: ['1031', '1071', '1051', '1061'],
      name: '核电关键材料全国重点实验室',
      listUrl: 'https://skl4nm.shu.edu.cn/sybk/tzgg.htm',
      additionalListUrls: [
        'https://skl4nm.shu.edu.cn/sybk/yjcg.htm',
        'https://skl4nm.shu.edu.cn/sybk/zszp.htm',
        'https://skl4nm.shu.edu.cn/sybk/kfkt.htm',
      ],
      columnNames: ['通知公告', '研究成果', '招生招聘', '开放课题'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'sklar',
      searchOwner: '2132008928',
      searchColumnIds: ['1502'],
      name: '先进耐火材料全国实验室',
      listUrl: 'https://sklar.shu.edu.cn/sybk/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'sklass',
      searchOwner: '1339981612',
      searchColumnIds: ['1044'],
      name: '先进特殊钢全国重点实验室',
      listUrl: 'https://sklass.shu.edu.cn/index/gsgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'fpd',
      searchOwner: '1383592681',
      searchColumnIds: ['1111', '1113', '1112'],
      name: '新型显示技术及应用集成教育部重点实验室',
      listUrl: 'https://fpd.shu.edu.cn/kfyjl/tzgg.htm',
      additionalListUrls: [
        'https://fpd.shu.edu.cn/kfyjl/xwzx.htm',
        'https://fpd.shu.edu.cn/kfyjl/xsjl1.htm',
      ],
      columnNames: ['通知公告', '新闻中心', '学术交流'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
      ),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'ms',
      searchOwner: '1657519516',
      searchColumnIds: ['1245'],
      name: '管理学院',
      listUrl: 'https://ms.shu.edu.cn/syzl/zytz.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'qwc',
      searchOwner: '1600705936',
      searchColumnIds: ['1086'],
      name: '钱伟长学院',
      listUrl: 'https://qwc.shu.edu.cn/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scicol',
      searchOwner: '1381981180',
      searchColumnIds: ['1006', '1009', '1010'],
      name: '理学院',
      listUrl: 'https://scicol.shu.edu.cn/sy/tzgg.htm',
      additionalListUrls: [
        'https://scicol.shu.edu.cn/sy/yjsjw.htm',
        'https://scicol.shu.edu.cn/sy/bksjw.htm',
      ],
      columnNames: ['通知公告', '研究生教务', '本科生教务'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scie',
      searchOwner: '1508948420',
      searchColumnIds: ['1065', '1070'],
      name: '通信与信息工程学院',
      listUrl: 'https://scie.shu.edu.cn/sywzzl/tzgg.htm',
      additionalListUrls: ['https://scie.shu.edu.cn/sywzzl/jxxx.htm'],
      columnNames: ['通知公告', '教学信息'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'xiangying',
      searchOwner: '1600705763',
      searchColumnIds: ['1031'],
      name: '翔英学院',
      listUrl: 'https://xiangying.shu.edu.cn/syxgzlpzd/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfs',
      searchOwner: '1507601601',
      searchColumnIds: ['1141'],
      name: '外国语学院',
      listUrl: 'https://sfs.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sjc',
      searchOwner: '1496137373',
      searchColumnIds: ['1003'],
      name: '新闻传播学院',
      listUrl: 'https://sjc.shu.edu.cn/tg/xygg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.sjcList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sme',
      searchOwner: '1880700804',
      searchColumnIds: ['1030'],
      name: '微电子学院',
      listUrl: 'https://sme.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'smes',
      searchOwner: '1570605493',
      searchColumnIds: ['1016', '1015'],
      name: '力学与工程科学学院',
      listUrl: 'https://smes.shu.edu.cn/index/xsxx.htm',
      additionalListUrls: ['https://smes.shu.edu.cn/index/tzgg.htm'],
      columnNames: ['学生信息', '通知公告'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sociology',
      searchOwner: '1658331948',
      searchColumnIds: ['1103'],
      name: '社会学院',
      listUrl: 'https://sociology.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'tiyu',
      searchOwner: '1604366189',
      searchColumnIds: ['1073'],
      name: '体育学院',
      listUrl: 'https://tiyu.shu.edu.cn/syxwzl/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cs',
      searchOwner: '2105799499',
      searchColumnIds: ['1081', '1061'],
      name: '计算机工程与科学学院',
      listUrl: 'https://cs.shu.edu.cn/index/zytz.htm',
      additionalListUrls: ['https://cs.shu.edu.cn/index/xwdt.htm'],
      columnNames: ['重要通知', '新闻动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.xwLt,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ai',
      searchOwner: '1682478267',
      searchColumnIds: ['1150'],
      name: '未来技术学院',
      listUrl: 'https://ai.shu.edu.cn/xwtz/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.nestedListUl),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'medicine',
      searchOwner: '1556105810',
      searchColumnIds: ['1054'],
      name: '医学院',
      listUrl: 'https://medicine.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.listPageList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'music',
      searchOwner: '1652596067',
      searchColumnIds: ['1024', '1175'],
      name: '音乐学院',
      listUrl: 'https://music.shu.edu.cn/xwzx/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'modart',
      searchOwner: '1580473210',
      searchColumnIds: ['1087', '1009', '1010'],
      name: '巴黎国际时装艺术学院',
      listUrl: 'https://modart.shu.edu.cn/tzgg.htm',
      additionalListUrls: [
        'https://modart.shu.edu.cn/xyzx/xyxw.htm',
        'https://modart.shu.edu.cn/xyzx/sszx1.htm',
      ],
      columnNames: ['通知公告', '学院新闻', '时尚资讯'],
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightListUl),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'safa',
      searchOwner: '1676726341',
      searchColumnIds: ['1122'],
      name: '上海美术学院',
      listUrl: 'https://safa.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cce',
      searchOwner: '1429464619',
      searchColumnIds: ['1014', '1542', '1464'],
      name: '继续教育学院',
      listUrl: 'https://cce.shu.edu.cn/symk/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.listRLb),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'zhgy',
      searchOwner: '1997493522',
      searchColumnIds: ['1021'],
      name: '卓越工程师学院',
      listUrl: 'https://zhgy.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightListUl),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfa',
      searchOwner: '1600705553',
      searchColumnIds: ['1212'],
      name: '上海电影学院',
      listUrl: 'https://sfa.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.filmNotice),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'shvfs',
      name: '上海温哥华电影学院',
      listUrl: 'https://www.shvfs.cn/site/news/4',
      additionalListUrls: ['https://www.shvfs.cn/site/news/8'],
      columnNames: ['学院动态', '媒体关注'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.shvfsNews,
        hideListColumn: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mkszyxy',
      searchOwner: '1653118915',
      searchColumnIds: ['1129'],
      name: '马克思主义学院',
      listUrl: 'https://mkszyxy.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'law',
      searchOwner: '1498770058',
      searchColumnIds: ['1012'],
      name: '法学院',
      listUrl: 'https://law.shu.edu.cn/zxzx/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'schim',
      searchOwner: '1861247740',
      searchColumnIds: ['1375'],
      name: '文化遗产与信息管理学院',
      listUrl: 'https://schim.shu.edu.cn/xwdt/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.onlyList,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'soe',
      searchOwner: '1657520282',
      searchColumnIds: ['1192'],
      name: '经济学院',
      listUrl: 'https://soe.shu.edu.cn/index/sytzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'silc',
      searchOwner: '1542326829',
      searchColumnIds: ['1035'],
      name: '悉尼工商学院',
      listUrl: 'https://silc.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'auto',
      searchOwner: '1498552290',
      searchColumnIds: ['1123'],
      name: '机电工程与自动化学院',
      listUrl: 'https://auto.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'bio',
      searchOwner: '1656223304',
      searchColumnIds: ['1145'],
      name: '生命科学学院',
      listUrl: 'https://bio.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ulisboas',
      searchOwner: '1852683123',
      searchColumnIds: ['1049'],
      name: '里斯本学院',
      listUrl: 'https://ulisboas.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'utseus',
      searchOwner: '1430791623',
      searchColumnIds: ['1010'],
      name: '中欧工程技术学院',
      listUrl: 'https://utseus.shu.edu.cn/symkzj/gg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.contentBoxList),
      group: AnnouncementSourceGroup.college,
    ),
  ];

  // Follow the university's organization directory. Party and mass
  // organizations share the administrative section in this two-group menu.
  static const _administrativeDepartmentOrder = <String>[
    'xgb',
    'dwygb',
    'youth',
    'ac',
    'hr',
    'kyglb',
    'gs',
    'bksy',
    'cwc',
    'alumni',
    'its',
    'global',
    'hbb',
    'baoweichu',
    'sbc',
  ];

  // The directory lists the first three as affiliated units; the internal
  // hospital and nonprofit foundation are grouped with these service entities.
  static const _affiliatedInstitutionOrder = <String>[
    'lib',
    'archive',
    'museum',
    'xyy',
    'shuedf',
  ];

  static const _researchInstituteOrder = <String>[
    'mgi',
    'suitm',
    'jhai',
    'igs',
    'ihe',
    'cast',
    'icn',
    'adri',
    'jgzx',
    'suns',
    'skl4nm',
    'sklar',
    'sklass',
    'fpd',
  ];

  static const _groupOrders = {
    AnnouncementSourceGroup.administrativeDepartment:
        _administrativeDepartmentOrder,
    AnnouncementSourceGroup.affiliatedInstitution: _affiliatedInstitutionOrder,
    AnnouncementSourceGroup.researchInstitute: _researchInstituteOrder,
  };

  static List<AnnouncementSource> inGroup(AnnouncementSourceGroup group) {
    if (group == AnnouncementSourceGroup.college) {
      return [
        for (final category in AnnouncementCollegeCategory.values)
          ...inCollegeCategory(category),
      ];
    }
    final order = _groupOrders[group];
    if (order != null) {
      final sourcesById = {
        for (final source in all)
          if (source.group == group) source.id: source,
      };
      return [
        for (final id in order)
          if (sourcesById.containsKey(id)) sourcesById[id]!,
        for (final source in sourcesById.values)
          if (!order.contains(source.id)) source,
      ];
    }
    return all.where((source) => source.group == group).toList(growable: false);
  }

  static List<AnnouncementSource> inCollegeCategory(
      AnnouncementCollegeCategory category) {
    final sourcesById = {
      for (final source in all)
        if (source.group == AnnouncementSourceGroup.college) source.id: source,
    };
    final sources = <AnnouncementSource>[];
    for (final id in category.sourceIds) {
      final source = sourcesById[id];
      if (source != null) sources.add(source);
    }
    if (category == AnnouncementCollegeCategory.other) {
      final categorizedIds = AnnouncementCollegeCategory.values
          .expand((value) => value.sourceIds)
          .toSet();
      sources.addAll(sourcesById.values
          .where((source) => !categorizedIds.contains(source.id)));
    }
    return sources;
  }

  static String _normalizedHost(String host) {
    final normalized = host.toLowerCase();
    return normalized.startsWith('www.') ? normalized.substring(4) : normalized;
  }

  static final Map<String, AnnouncementSource> _sourcesByHost = () {
    final sourcesByHost = <String, AnnouncementSource>{};
    for (final source in all) {
      for (final listUrl in source.listUrls) {
        final uri = Uri.tryParse(listUrl);
        if (uri == null || uri.host.isEmpty) continue;
        sourcesByHost.putIfAbsent(_normalizedHost(uri.host), () => source);
      }
    }
    return sourcesByHost;
  }();

  /// Resolves the article parser by its site's host, preserving a matching
  /// preferred source when multiple announcement columns share the same site.
  static AnnouncementSource? forUrl(String url, {String? preferredSourceId}) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    final host = _normalizedHost(uri.host);
    for (final source in all) {
      if (source.id != preferredSourceId) continue;
      if (source.listUrls.any((listUrl) {
        final sourceUri = Uri.tryParse(listUrl);
        return sourceUri != null && _normalizedHost(sourceUri.host) == host;
      })) {
        return source;
      }
      break;
    }
    return _sourcesByHost[host];
  }

  static AnnouncementSource byId(String? id) {
    for (final source in all) {
      if (source.id == id) return source;
    }
    return official;
  }
}
