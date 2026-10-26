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
  schoolDepartment('学校下属部门'),
  college('学院'),
  researchInstitute('研究院所');

  const AnnouncementSourceGroup(this.label);

  final String label;
}

const _vsbAuthorValueSelectors = [
  'tr[valign="middle"][height="20"] font[face=""] > span',
];

class AnnouncementSourceAdapter {
  const AnnouncementSourceAdapter({
    required this.listFormat,
    this.authorLabelSelectors = const ['.xx span', 'p span'],
    this.authorValueSelectors = const [
      'span[id*="lblUser"]',
      'span[id*="lblAuthor"]',
      'span[id*="articleAuthor"]',
    ],
    this.hideListColumn = false,
    this.hideDetailDepartment = false,
  });

  final AnnouncementListFormat listFormat;
  final List<String> authorLabelSelectors;
  final List<String> authorValueSelectors;
  final bool hideListColumn;
  final bool hideDetailDepartment;
}

class AnnouncementSource {
  const AnnouncementSource({
    required this.id,
    required this.name,
    required this.listUrl,
    required this.adapter,
    this.additionalListUrls = const [],
    this.columnNames = const [],
    this.group = AnnouncementSourceGroup.schoolDepartment,
  });

  final String id;
  final String name;
  final String listUrl;
  final AnnouncementSourceAdapter adapter;
  AnnouncementListFormat get format => adapter.listFormat;
  final List<String> additionalListUrls;
  final List<String> columnNames;
  final AnnouncementSourceGroup group;

  List<String> get listUrls => [listUrl, ...additionalListUrls];

  static const officialId = 'shu';

  static const official = AnnouncementSource(
    id: officialId,
    name: '上海大学官网',
    listUrl: 'https://www.shu.edu.cn/tzgg.htm',
    adapter: AnnouncementSourceAdapter(
      listFormat: AnnouncementListFormat.shuHome,
      authorLabelSelectors: ['.xx span'],
      authorValueSelectors: [],
    ),
    group: AnnouncementSourceGroup.schoolPortal,
  );

  static const all = <AnnouncementSource>[
    official,
    AnnouncementSource(
      id: 'bksy',
      name: '本科生院',
      listUrl: 'https://bksy.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    ),
    AnnouncementSource(
      id: 'bkzsw',
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
      name: '本科生工作处',
      listUrl: 'https://xgb.shu.edu.cn/xgdt/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.artList,
        authorValueSelectors: [r'a[id$="_hypFirst"]'],
      ),
    ),
    AnnouncementSource(
      id: 'dwygb',
      name: '研究生工作处',
      listUrl: 'https://dwygb.shu.edu.cn/xwzx/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
    ),
    AnnouncementSource(
      id: 'gs',
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
      name: '财务处',
      listUrl: 'https://cwc.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.centreList),
    ),
    AnnouncementSource(
      id: 'lib',
      name: '图书馆',
      listUrl: 'https://lib.shu.edu.cn/sho/ggxx.htm',
      additionalListUrls: ['https://lib.shu.edu.cn/sho/zydt.htm'],
      columnNames: ['通知公告', '资源动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.rightList,
        hideListColumn: true,
        hideDetailDepartment: true,
      ),
    ),
    AnnouncementSource(
      id: 'alumni',
      name: '对外联络处',
      listUrl: 'https://alumni.shu.edu.cn/xwggzx/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'shuedf',
      name: '上海大学教育发展基金会',
      listUrl: 'https://shuedf.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
    ),
    AnnouncementSource(
      id: 'kyglb',
      name: '科研管理部',
      listUrl: 'https://kyglb.shu.edu.cn/dhl/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.unorderedList),
    ),
    AnnouncementSource(
      id: 'baoweichu',
      name: '保卫处',
      listUrl: 'https://baoweichu.shu.edu.cn/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
    ),
    AnnouncementSource(
      id: 'its',
      name: '信息化工作办公室',
      listUrl: 'https://newits.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.onlyList,
        authorValueSelectors: _vsbAuthorValueSelectors,
      ),
    ),
    AnnouncementSource(
      id: 'youth',
      name: '上海大学共青团委员会',
      listUrl: 'https://youth.shu.edu.cn/syxzlly/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
    ),
    AnnouncementSource(
      id: 'global',
      name: '国际部',
      listUrl: 'https://global.shu.edu.cn/cd/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
        authorValueSelectors: _vsbAuthorValueSelectors,
      ),
    ),
    AnnouncementSource(
      id: 'hbb',
      name: '后勤保障部',
      listUrl: 'https://hbb.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'xyy',
      name: '校医院',
      listUrl: 'https://xyy.shu.edu.cn/sylm/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
    ),
    AnnouncementSource(
      id: 'archive',
      name: '档案馆',
      listUrl: 'https://dangan.shu.edu.cn/gqgk/xxfb/fwgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
        authorValueSelectors: _vsbAuthorValueSelectors,
      ),
    ),
    AnnouncementSource(
      id: 'sbc',
      name: '实验室与设备管理处',
      listUrl: 'https://sbc.shu.edu.cn/tg/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
    ),
    AnnouncementSource(
      id: 'hr',
      name: '人事处',
      listUrl: 'https://hr.shu.edu.cn/xwgg1/xwgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
    ),
    AnnouncementSource(
      id: 'cie',
      name: '国际教育学院',
      listUrl: 'https://cie.shu.edu.cn/tg/xytz.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.listPage),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cla',
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
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mat',
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
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mba',
      name: 'MBA教育管理中心',
      listUrl: 'https://mba.shu.edu.cn/cslm/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.mbaList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mgi',
      name: '材料基因组工程研究院',
      listUrl: 'https://mgi.shu.edu.cn/index/lmzl/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'suitm',
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
      name: '亚洲人口研究中心',
      listUrl: 'https://adrichn.shu.edu.cn/sylmnr/ggl.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'cast',
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
      name: '高等教育研究所',
      listUrl: 'https://ihe.shu.edu.cn/sybk/gjdt.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'jgzx',
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
      name: '无人艇工程研究院',
      listUrl: 'https://jhai.shu.edu.cn/sylm/xwdt.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.vsbTable),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'museum',
      name: '博物馆',
      listUrl: 'https://museum.shu.edu.cn/bggk/xwkd.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
      group: AnnouncementSourceGroup.schoolDepartment,
    ),
    AnnouncementSource(
      id: 'suns',
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
      name: '先进耐火材料全国实验室',
      listUrl: 'https://sklar.shu.edu.cn/sybk/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'sklass',
      name: '先进特殊钢全国重点实验室',
      listUrl: 'https://sklass.shu.edu.cn/index/gsgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.whitespaceList),
      group: AnnouncementSourceGroup.researchInstitute,
    ),
    AnnouncementSource(
      id: 'fpd',
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
      name: '管理学院',
      listUrl: 'https://ms.shu.edu.cn/syzl/zytz.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'qwc',
      name: '钱伟长学院',
      listUrl: 'https://qwc.shu.edu.cn/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scicol',
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
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scie',
      name: '通信与信息工程学院',
      listUrl: 'https://scie.shu.edu.cn/sywzzl/tzgg.htm',
      additionalListUrls: ['https://scie.shu.edu.cn/sywzzl/jxxx.htm'],
      columnNames: ['通知公告', '教学信息'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
        hideListColumn: true,
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'xiangying',
      name: '翔英学院',
      listUrl: 'https://xiangying.shu.edu.cn/syxgzlpzd/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.vsbNewList,
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfs',
      name: '外国语学院',
      listUrl: 'https://sfs.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sjc',
      name: '新闻传播学院',
      listUrl: 'https://sjc.shu.edu.cn/tg/xygg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.sjcList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sme',
      name: '微电子学院',
      listUrl: 'https://sme.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'smes',
      name: '力学与工程科学学院',
      listUrl: 'https://smes.shu.edu.cn/index/xsxx.htm',
      additionalListUrls: ['https://smes.shu.edu.cn/index/tzgg.htm'],
      columnNames: ['学生信息', '通知公告'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.bareSpanList,
        hideListColumn: true,
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sociology',
      name: '社会学院',
      listUrl: 'https://sociology.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'tiyu',
      name: '体育学院',
      listUrl: 'https://tiyu.shu.edu.cn/syxwzl/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cs',
      name: '计算机工程与科学学院',
      listUrl: 'https://cs.shu.edu.cn/index/zytz.htm',
      additionalListUrls: ['https://cs.shu.edu.cn/index/xwdt.htm'],
      columnNames: ['重要通知', '新闻动态'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.xwLt,
        authorLabelSelectors: ['p span'],
        authorValueSelectors: [],
        hideDetailDepartment: true,
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ai',
      name: '未来技术学院',
      listUrl: 'https://ai.shu.edu.cn/xwtz/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.nestedListUl),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'medicine',
      name: '医学院',
      listUrl: 'https://medicine.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.listPageList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'music',
      name: '音乐学院',
      listUrl: 'https://music.shu.edu.cn/xwzx/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'modart',
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
      name: '上海美术学院',
      listUrl: 'https://safa.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cce',
      name: '继续教育学院',
      listUrl: 'https://cce.shu.edu.cn/symk/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.listRLb),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'zhgy',
      name: '卓越工程师学院',
      listUrl: 'https://zhgy.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightListUl),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfa',
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
      name: '马克思主义学院',
      listUrl: 'https://mkszyxy.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'law',
      name: '法学院',
      listUrl: 'https://law.shu.edu.cn/zxzx/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'schim',
      name: '文化遗产与信息管理学院',
      listUrl: 'https://schim.shu.edu.cn/xwdt/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.onlyList,
        authorLabelSelectors: ['span[id*="lblAuthor"]'],
        authorValueSelectors: [r'a[id$="_hypUser"]'],
      ),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'soe',
      name: '经济学院',
      listUrl: 'https://soe.shu.edu.cn/index/sytzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'silc',
      name: '悉尼工商学院',
      listUrl: 'https://silc.shu.edu.cn/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'auto',
      name: '机电工程与自动化学院',
      listUrl: 'https://auto.shu.edu.cn/synr/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'bio',
      name: '生命科学学院',
      listUrl: 'https://bio.shu.edu.cn/sylm/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ulisboas',
      name: '里斯本学院',
      listUrl: 'https://ulisboas.shu.edu.cn/index/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.onlyList),
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'utseus',
      name: '中欧工程技术学院',
      listUrl: 'https://utseus.shu.edu.cn/symkzj/gg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.contentBoxList),
      group: AnnouncementSourceGroup.college,
    ),
  ];

  static const _schoolDepartmentOrder = <String>[
    'bksy',
    'gs',
    'xgb',
    'dwygb',
    'youth',
    'kyglb',
    'global',
    'alumni',
    'shuedf',
    'hr',
    'cwc',
    'sbc',
    'lib',
    'archive',
    'museum',
    'its',
    'hbb',
    'baoweichu',
    'xyy',
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

  static List<AnnouncementSource> inGroup(AnnouncementSourceGroup group) {
    if (group == AnnouncementSourceGroup.college) {
      return [
        for (final category in AnnouncementCollegeCategory.values)
          ...inCollegeCategory(category),
      ];
    }
    if (group == AnnouncementSourceGroup.schoolDepartment ||
        group == AnnouncementSourceGroup.researchInstitute) {
      final order = group == AnnouncementSourceGroup.schoolDepartment
          ? _schoolDepartmentOrder
          : _researchInstituteOrder;
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
