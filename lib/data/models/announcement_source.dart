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
}

enum AnnouncementSourceGroup { campus, college }

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
    this.group = AnnouncementSourceGroup.campus,
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
      id: 'xgb',
      name: '本科生工作处',
      listUrl: 'https://xgb.shu.edu.cn/xgdt/tzgg.htm',
      adapter:
          AnnouncementSourceAdapter(listFormat: AnnouncementListFormat.artList),
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
          listFormat: AnnouncementListFormat.onlyList),
    ),
    AnnouncementSource(
      id: 'youth',
      name: '共青团上海大学',
      listUrl: 'https://youth.shu.edu.cn/syxzlly/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.rightList),
    ),
    AnnouncementSource(
      id: 'global',
      name: '国际部',
      listUrl: 'https://global.shu.edu.cn/cd/tzgg.htm',
      adapter: AnnouncementSourceAdapter(
          listFormat: AnnouncementListFormat.bareSpanList),
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
          listFormat: AnnouncementListFormat.bareSpanList),
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
      group: AnnouncementSourceGroup.college,
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
      columnNames: ['重要通知'],
      adapter: AnnouncementSourceAdapter(
        listFormat: AnnouncementListFormat.xwLt,
        authorLabelSelectors: ['p span'],
        authorValueSelectors: [],
        hideListColumn: true,
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

  static List<AnnouncementSource> inGroup(AnnouncementSourceGroup group) =>
      all.where((source) => source.group == group).toList(growable: false);

  static AnnouncementSource byId(String? id) {
    for (final source in all) {
      if (source.id == id) return source;
    }
    return official;
  }
}
