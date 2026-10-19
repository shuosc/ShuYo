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

class AnnouncementSource {
  const AnnouncementSource({
    required this.id,
    required this.name,
    required this.listUrl,
    required this.format,
    this.additionalListUrls = const [],
    this.columnNames = const [],
    this.group = AnnouncementSourceGroup.campus,
  });

  final String id;
  final String name;
  final String listUrl;
  final AnnouncementListFormat format;
  final List<String> additionalListUrls;
  final List<String> columnNames;
  final AnnouncementSourceGroup group;

  List<String> get listUrls => [listUrl, ...additionalListUrls];

  static const officialId = 'shu';

  static const official = AnnouncementSource(
    id: officialId,
    name: '上海大学官网',
    listUrl: 'https://www.shu.edu.cn/tzgg.htm',
    format: AnnouncementListFormat.shuHome,
  );

  static const all = <AnnouncementSource>[
    official,
    AnnouncementSource(
      id: 'bksy',
      name: '本科生院',
      listUrl: 'https://bksy.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
    ),
    AnnouncementSource(
      id: 'xgb',
      name: '本科生工作处',
      listUrl: 'https://xgb.shu.edu.cn/xgdt/tzgg.htm',
      format: AnnouncementListFormat.artList,
    ),
    AnnouncementSource(
      id: 'dwygb',
      name: '研究生工作处',
      listUrl: 'https://dwygb.shu.edu.cn/xwzx/tzgg.htm',
      format: AnnouncementListFormat.artList,
    ),
    AnnouncementSource(
      id: 'gs',
      name: '研究生院',
      listUrl: 'https://gs.shu.edu.cn/xwlb/py.htm',
      format: AnnouncementListFormat.vsbTable,
    ),
    AnnouncementSource(
      id: 'cwc',
      name: '财务处',
      listUrl: 'https://cwc.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.centreList,
    ),
    AnnouncementSource(
      id: 'lib',
      name: '图书馆',
      listUrl: 'https://lib.shu.edu.cn/sho/ggxx.htm',
      additionalListUrls: ['https://lib.shu.edu.cn/sho/zydt.htm'],
      columnNames: ['通知公告', '资源动态'],
      format: AnnouncementListFormat.rightList,
    ),
    AnnouncementSource(
      id: 'kyglb',
      name: '科研管理部',
      listUrl: 'https://kyglb.shu.edu.cn/dhl/tzgg.htm',
      format: AnnouncementListFormat.unorderedList,
    ),
    AnnouncementSource(
      id: 'baoweichu',
      name: '保卫处',
      listUrl: 'https://baoweichu.shu.edu.cn/ggl.htm',
      format: AnnouncementListFormat.onlyList,
    ),
    AnnouncementSource(
      id: 'its',
      name: '信息化工作办公室',
      listUrl: 'https://newits.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
    ),
    AnnouncementSource(
      id: 'cie',
      name: '国际教育学院',
      listUrl: 'https://cie.shu.edu.cn/tg/xytz.htm',
      format: AnnouncementListFormat.listPage,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cla',
      name: '文学院',
      listUrl: 'https://cla.shu.edu.cn/tg/tzgg.htm',
      format: AnnouncementListFormat.sjList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ece',
      name: '环境与化学工程学院',
      listUrl: 'https://ece.shu.edu.cn/sylm/bksjx.htm',
      additionalListUrls: ['https://ece.shu.edu.cn/sylm/yjsjx.htm'],
      columnNames: ['本科生教学', '研究生教学'],
      format: AnnouncementListFormat.rightListUl,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mat',
      name: '材料科学与工程学院',
      listUrl: 'https://mat.shu.edu.cn/sycdlm/tzgg/bks.htm',
      additionalListUrls: ['https://mat.shu.edu.cn/sycdlm/tzgg/yjs.htm'],
      columnNames: ['通知公告(本科生)', '通知公告(研究生)'],
      format: AnnouncementListFormat.rightListUl,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mba',
      name: 'MBA教育管理中心',
      listUrl: 'https://mba.shu.edu.cn/cslm/tzgg.htm',
      format: AnnouncementListFormat.mbaList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mgi',
      name: '材料基因组工程研究院',
      listUrl: 'https://mgi.shu.edu.cn/index/lmzl/tzgg.htm',
      format: AnnouncementListFormat.artList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ms',
      name: '管理学院',
      listUrl: 'https://ms.shu.edu.cn/syzl/zytz.htm',
      format: AnnouncementListFormat.artList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'qwc',
      name: '钱伟长学院',
      listUrl: 'https://qwc.shu.edu.cn/tzgg.htm',
      format: AnnouncementListFormat.artList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scicol',
      name: '理学院',
      listUrl: 'https://scicol.shu.edu.cn/sy/tzgg.htm',
      additionalListUrls: ['https://scicol.shu.edu.cn/sy/yjsjw.htm'],
      columnNames: ['通知公告', '研究生教务'],
      format: AnnouncementListFormat.vsbNewList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'scie',
      name: '通信与信息工程学院',
      listUrl: 'https://scie.shu.edu.cn/sywzzl/tzgg.htm',
      additionalListUrls: ['https://scie.shu.edu.cn/sywzzl/jxxx.htm'],
      columnNames: ['通知公告', '教学信息'],
      format: AnnouncementListFormat.vsbNewList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfs',
      name: '外国语学院',
      listUrl: 'https://sfs.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.rightList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sjc',
      name: '新闻传播学院',
      listUrl: 'https://sjc.shu.edu.cn/tg/xygg.htm',
      format: AnnouncementListFormat.sjcList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sme',
      name: '微电子学院',
      listUrl: 'https://sme.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.rightList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'smes',
      name: '力学与工程科学学院',
      listUrl: 'https://smes.shu.edu.cn/index/xsxx.htm',
      additionalListUrls: ['https://smes.shu.edu.cn/index/tzgg.htm'],
      columnNames: ['学生信息', '通知公告'],
      format: AnnouncementListFormat.bareSpanList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sociology',
      name: '社会学院',
      listUrl: 'https://sociology.shu.edu.cn/synr/tzgg.htm',
      format: AnnouncementListFormat.rightList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'tiyu',
      name: '体育学院',
      listUrl: 'https://tiyu.shu.edu.cn/syxwzl/tzgg.htm',
      format: AnnouncementListFormat.rightList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cs',
      name: '计算机工程与科学学院',
      listUrl: 'https://cs.shu.edu.cn/index/xwdt.htm',
      additionalListUrls: ['https://cs.shu.edu.cn/index/zytz.htm'],
      columnNames: ['新闻动态', '重要通知'],
      format: AnnouncementListFormat.xwLt,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ai',
      name: '未来技术学院',
      listUrl: 'https://ai.shu.edu.cn/xwtz/tzgg.htm',
      format: AnnouncementListFormat.nestedListUl,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'medicine',
      name: '医学院',
      listUrl: 'https://medicine.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.listPageList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'music',
      name: '音乐学院',
      listUrl: 'https://music.shu.edu.cn/xwzx/tzgg.htm',
      format: AnnouncementListFormat.artList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'safa',
      name: '上海美术学院',
      listUrl: 'https://safa.shu.edu.cn/synr/tzgg.htm',
      format: AnnouncementListFormat.bareSpanList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'cce',
      name: '继续教育学院',
      listUrl: 'https://cce.shu.edu.cn/symk/tzgg.htm',
      format: AnnouncementListFormat.listRLb,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'zhgy',
      name: '卓越工程师学院',
      listUrl: 'https://zhgy.shu.edu.cn/tzgg.htm',
      format: AnnouncementListFormat.rightListUl,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'sfa',
      name: '上海电影学院',
      listUrl: 'https://sfa.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.filmNotice,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'mkszyxy',
      name: '马克思主义学院',
      listUrl: 'https://mkszyxy.shu.edu.cn/sylm/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'law',
      name: '法学院',
      listUrl: 'https://law.shu.edu.cn/zxzx/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'schim',
      name: '文化遗产与信息管理学院',
      listUrl: 'https://schim.shu.edu.cn/xwdt/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'soe',
      name: '经济学院',
      listUrl: 'https://soe.shu.edu.cn/index/sytzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'silc',
      name: '悉尼工商学院',
      listUrl: 'https://silc.shu.edu.cn/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'auto',
      name: '机电工程与自动化学院',
      listUrl: 'https://auto.shu.edu.cn/synr/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'bio',
      name: '生命科学学院',
      listUrl: 'https://bio.shu.edu.cn/sylm/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'ulisboas',
      name: '里斯本学院',
      listUrl: 'https://ulisboas.shu.edu.cn/index/tzgg.htm',
      format: AnnouncementListFormat.onlyList,
      group: AnnouncementSourceGroup.college,
    ),
    AnnouncementSource(
      id: 'utseus',
      name: '中欧工程技术学院',
      listUrl: 'https://utseus.shu.edu.cn/symkzj/gg.htm',
      format: AnnouncementListFormat.contentBoxList,
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
