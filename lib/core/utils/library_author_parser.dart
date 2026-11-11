/// 图书作者角色类型
enum LibraryAuthorRole {
  /// 著 / 著作 (主要作者)
  author,

  /// 原著 / 原作 (适用于改编本、影视同名书等)
  original,

  /// 改编 / 改写 / 续写
  adapter,

  /// 翻译 / 译者 / 主译
  translator,

  /// 编 / 主编 / 编著 / 整理 / 选编
  editor,

  /// 绘 / 绘画 / 插画
  illustrator,
}

/// 解析后的单个责任人实体
class LibraryAuthorEntity {
  const LibraryAuthorEntity({
    required this.name,
    this.originalName,
    this.countryCode,
    this.countryName,
    this.isRegion = false,
    this.isAncient = false,
    required this.role,
  });

  /// 纯姓名 (如: 达妮埃尔·齐布尔斯基、东野圭吾、林海音)
  final String name;

  /// 外文原名 (如: Popper, K.R.、Erald Kolasi)
  final String? originalName;

  /// ISO 3166-1 alpha-2 两位大写代码 (如: US, JP, GB, HK, TW, CN)
  final String? countryCode;

  /// 规范中文国家/朝代/地名 (如: 美国、日本、中国香港、清代)
  final String? countryName;

  /// 是否为中国特别行政区/地区 (中国香港、中国澳门、中国台湾)
  final bool isRegion;

  /// 是否为中国古代朝代 (清代、明代、唐代等)
  final bool isAncient;

  /// 承担的角色
  final LibraryAuthorRole role;

  /// 是否为纯中国大陆作者 (不需要显示国旗)
  bool get isMainlandChina => countryCode == 'CN' && !isAncient && !isRegion;

  /// 获取对应的国家/地区国旗 Emoji
  /// 规则：
  /// - 纯中国大陆 (CN): 不显示国旗 (返回 null)
  /// - 中国古代朝代: 不显示国旗 (返回 null)
  /// - 中国香港 (HK)、中国澳门 (MO)、中国台湾 (TW): 显示对应的地区旗帜 🇭🇰, 🇲🇴, 🇹🇼
  /// - 其他外国 (US, JP, GB 等): 显示对应国家的国旗 Emoji 🇺🇸, 🇯🇵, 🇬🇧
  String? get flagEmoji {
    if (countryCode == null) return null;
    if (isAncient) return null;
    if (isMainlandChina) return null;
    return _isoCodeToEmoji(countryCode!);
  }

  /// 获取展示用的前置标签文本 (包含国旗与��全的地名/国名)
  /// 规则:
  /// - 纯中国大陆: 无前缀
  /// - 中国古籍朝代: `[清代]`、`[唐代]` (不带国旗)
  /// - 中国港澳台: `🇭🇰 中国香港`、`🇲🇴 中国澳门`、`🇹🇼 中国台湾`
  /// - 外国: `🇺🇸 美国`、`🇯🇵 日本`、`🇬🇧 英国`
  String? get badgeText {
    if (isMainlandChina || countryCode == null) return null;
    if (isAncient) {
      final dynasty = (countryName != null && countryName!.isNotEmpty)
          ? countryName![0]
          : '古';
      return '[$dynasty]';
    }
    final flag = flagEmoji;
    final name = countryName ?? countryCode!;
    if (flag != null && flag.isNotEmpty) {
      return '$flag $name';
    }
    return '[$name]';
  }

  /// 转换为用于单行紧凑或列表显示的个人格式
  /// 规则: `(<国旗>德国)作者名` (国旗挪进括号内部)
  /// 如: "(🇩🇪德国)普朗特" 或 "东野圭吾" 或 "(🇭🇰中国香港)金庸" 或 "[清]曹雪芹"
  String toDisplayString({bool showRole = false}) {
    String prefix = '';
    if (flagEmoji != null && flagEmoji!.isNotEmpty) {
      final country = countryName ?? countryCode ?? '';
      prefix = '($flagEmoji$country)';
    } else if (isAncient) {
      final dynasty = (countryName != null && countryName!.isNotEmpty)
          ? countryName![0]
          : '古';
      prefix = '[$dynasty]';
    } else if (badgeText != null) {
      prefix = '$badgeText';
    }
    final roleSuffix = showRole ? _roleToString(role) : '';
    return '$prefix$name$roleSuffix';
  }

  static String? _isoCodeToEmoji(String code) {
    if (code.length != 2) return null;
    final upper = code.toUpperCase();
    const base = 127397;
    final first = upper.codeUnitAt(0) + base;
    final second = upper.codeUnitAt(1) + base;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  static String _roleToString(LibraryAuthorRole role) {
    switch (role) {
      case LibraryAuthorRole.original:
        return ' 原著';
      case LibraryAuthorRole.adapter:
        return ' 改编';
      case LibraryAuthorRole.translator:
        return ' 译';
      case LibraryAuthorRole.editor:
        return ' 编';
      case LibraryAuthorRole.illustrator:
        return ' 绘';
      case LibraryAuthorRole.author:
        return ' 著';
    }
  }

  @override
  String toString() => toDisplayString(showRole: true);
}

/// 解析后的图书完整责任者集合
class ParsedBookAuthors {
  const ParsedBookAuthors({
    this.authors = const [],
    this.originals = const [],
    this.adapters = const [],
    this.translators = const [],
    this.editors = const [],
    this.illustrators = const [],
    this.hasEtAl = false,
  });

  /// 主要作者 (著)
  final List<LibraryAuthorEntity> authors;

  /// 原著者 (原著/原作)
  final List<LibraryAuthorEntity> originals;

  /// 改编/改写者
  final List<LibraryAuthorEntity> adapters;

  /// 译者
  final List<LibraryAuthorEntity> translators;

  /// 编纂/主编
  final List<LibraryAuthorEntity> editors;

  /// 绘图/插画者
  final List<LibraryAuthorEntity> illustrators;

  /// 是否包含 "... 等"、"等著"
  final bool hasEtAl;

  /// 是否为空
  bool get isEmpty =>
      authors.isEmpty &&
      originals.isEmpty &&
      adapters.isEmpty &&
      translators.isEmpty &&
      editors.isEmpty &&
      illustrators.isEmpty;

  /// 是否不为空
  bool get isNotEmpty => !isEmpty;

  /// 最优先的主要责任人列表 (原著优先，次选作者，再次选编者)
  List<LibraryAuthorEntity> get primaryAuthors {
    if (originals.isNotEmpty) return originals;
    if (authors.isNotEmpty) return authors;
    if (editors.isNotEmpty) return editors;
    if (adapters.isNotEmpty) return adapters;
    if (illustrators.isNotEmpty) return illustrators;
    return const [];
  }

  /// 第一责任人
  LibraryAuthorEntity? get firstAuthor =>
      primaryAuthors.isNotEmpty ? primaryAuthors.first : null;

  /// 格式化为单行完整且紧凑的展示文本
  /// 示例效果：
  /// - 纯中国作者: "余华 著"
  /// - 中国多位作者: "张晓晶, 李四 等 著"
  /// - 港澳台: "🇹🇼 中国台湾 · 林海音 著"
  /// - 翻译作品: "🇺🇸 美国 · 拉斯·昂格尔, 卡洛琳·钱德勒 著 / 张贝, 袁萌 译"
  /// - 原著+改编: "管致中, 夏恭恪 原著 / 孟桥 改编"
  String toDisplayString({int maxPrimary = 2, int maxTranslators = 2}) {
    if (isEmpty) return '-';

    final parts = <String>[];

    // 1. 原著或作者块
    if (originals.isNotEmpty) {
      final names = _formatListWithBadge(originals, maxPrimary);
      final etAl = (originals.length > maxPrimary || hasEtAl) ? ' 等' : '';
      parts.add('$names$etAl 原著');
    } else if (authors.isNotEmpty) {
      final names = _formatListWithBadge(authors, maxPrimary);
      final etAl = (authors.length > maxPrimary || hasEtAl) ? ' 等' : '';
      parts.add('$names$etAl 著');
    } else if (editors.isNotEmpty) {
      final names = _formatListWithBadge(editors, maxPrimary);
      final etAl = (editors.length > maxPrimary || hasEtAl) ? ' 等' : '';
      parts.add('$names$etAl 编');
    }

    // 2. 改编块
    if (adapters.isNotEmpty) {
      final names = _formatListWithBadge(adapters, maxPrimary);
      parts.add('$names 改编');
    }

    // 3. 译者块
    if (translators.isNotEmpty) {
      final shown =
          translators.take(maxTranslators).map((t) => t.name).join(', ');
      final etAl =
          (translators.length > maxTranslators || (hasEtAl && authors.isEmpty))
              ? ' 等'
              : '';
      parts.add('$shown$etAl 译');
    }

    // 4. 如果前面都没有，看看绘者
    if (parts.isEmpty && illustrators.isNotEmpty) {
      final names = _formatListWithBadge(illustrators, maxPrimary);
      parts.add('$names 绘');
    }

    return parts.join(' / ');
  }

  String _formatListWithBadge(List<LibraryAuthorEntity> list, int maxCount) {
    final takeItems = list.take(maxCount).toList();
    if (takeItems.isEmpty) return '';

    final firstWithBadge = takeItems.firstWhere(
      (a) => a.badgeText != null,
      orElse: () => takeItems.first,
    );

    final badge = firstWithBadge.badgeText;
    final names = takeItems.map((a) => a.name).join(', ');

    if (badge != null && badge.isNotEmpty) {
      return '$badge · $names';
    }
    return names;
  }
}

/// 权威作者解析器
class LibraryAuthorParser {
  /// 全球国家及地区、中国朝代权威映射字典
  /// 格式: [ISO-3166-1 2位代码, 规范中文名, 类型('foreign'|'region'|'ancient'|'mainland')]
  static const Map<String, List<String>> _countryDb = {
    // 港澳台特例 (region)：用旗帜 + 补全地名 (香港用区旗HK 🇭🇰，澳门用区旗MO 🇲🇴，台湾用中国国旗CN 🇨🇳)
    '中国香港': ['HK', '中国香港', 'region'],
    '香港': ['HK', '中国香港', 'region'],
    '中国澳门': ['MO', '中国澳门', 'region'],
    '澳门': ['MO', '中国澳门', 'region'],
    '中国台湾': ['CN', '中国台湾', 'region'],
    '台湾': ['CN', '中国台湾', 'region'],
    '台': ['CN', '中国台湾', 'region'],

    // 纯中国大陆 (mainland)：不显示国旗，不加前缀
    '中': ['CN', '中国', 'mainland'],
    '中国': ['CN', '中国', 'mainland'],
    '华': ['CN', '中国', 'mainland'],
    '大陆': ['CN', '中国', 'mainland'],

    // 中国历史朝代 (ancient)：不带国旗，只补朝代名
    '清': ['CN', '清', 'ancient'],
    '明': ['CN', '明', 'ancient'],
    '唐': ['CN', '唐', 'ancient'],
    '宋': ['CN', '宋', 'ancient'],
    '南宋': ['CN', '宋', 'ancient'],
    '北宋': ['CN', '宋', 'ancient'],
    '汉': ['CN', '汉', 'ancient'],
    '东汉': ['CN', '汉', 'ancient'],
    '東漢': ['CN', '汉', 'ancient'],
    '西汉': ['CN', '汉', 'ancient'],
    '北魏': ['CN', '魏', 'ancient'],
    '魏晋': ['CN', '晋', 'ancient'],
    '三国': ['CN', '魏', 'ancient'],
    '晋': ['CN', '晋', 'ancient'],
    '秦': ['CN', '秦', 'ancient'],
    '元': ['CN', '元', 'ancient'],
    '战国': ['CN', '周', 'ancient'],
    '春秋': ['CN', '周', 'ancient'],
    '民国': ['CN', '民国', 'ancient'],

    // 美洲 (foreign)
    '美': ['US', '美国', 'foreign'],
    '美国': ['US', '美国', 'foreign'],
    '加': ['CA', '加拿大', 'foreign'],
    '加拿大': ['CA', '加拿大', 'foreign'],
    '墨': ['MX', '墨西哥', 'foreign'],
    '墨西哥': ['MX', '墨西哥', 'foreign'],
    '巴': ['BR', '巴西', 'foreign'],
    '巴西': ['BR', '巴西', 'foreign'],
    '阿根廷': ['AR', '阿根廷', 'foreign'],
    '智利': ['CL', '智利', 'foreign'],
    '秘鲁': ['PE', '秘鲁', 'foreign'],
    '哥伦比亚': ['CO', '哥伦比亚', 'foreign'],
    '古巴': ['CU', '古巴', 'foreign'],
    '委内瑞拉': ['VE', '委内瑞拉', 'foreign'],
    '乌拉圭': ['UY', '乌拉圭', 'foreign'],

    // 亚洲 (foreign)
    '日': ['JP', '日本', 'foreign'],
    '日本': ['JP', '日本', 'foreign'],
    '韩': ['KR', '韩国', 'foreign'],
    '韩国': ['KR', '韩国', 'foreign'],
    '朝': ['KP', '朝鲜', 'foreign'],
    '朝鲜': ['KP', '朝鲜', 'foreign'],
    '印': ['IN', '印度', 'foreign'],
    '印度': ['IN', '印度', 'foreign'],
    '新': ['SG', '新加坡', 'foreign'],
    '新加坡': ['SG', '新加坡', 'foreign'],
    '马': ['MY', '马来西亚', 'foreign'],
    '马来西亚': ['MY', '马来西亚', 'foreign'],
    '泰': ['TH', '泰国', 'foreign'],
    '泰国': ['TH', '泰国', 'foreign'],
    '越': ['VN', '越南', 'foreign'],
    '越南': ['VN', '越南', 'foreign'],
    '印尼': ['ID', '印度尼西亚', 'foreign'],
    '印度尼西亚': ['ID', '印度尼西亚', 'foreign'],
    '菲': ['PH', '菲律宾', 'foreign'],
    '菲律宾': ['PH', '菲律宾', 'foreign'],
    '以': ['IL', '以色列', 'foreign'],
    '以色列': ['IL', '以色列', 'foreign'],
    '沙特': ['SA', '沙特阿拉伯', 'foreign'],
    '伊朗': ['IR', '伊朗', 'foreign'],
    '伊拉克': ['IQ', '伊拉克', 'foreign'],
    '土': ['TR', '土耳其', 'foreign'],
    '土耳其': ['TR', '土耳其', 'foreign'],
    '巴基斯坦': ['PK', '巴基斯坦', 'foreign'],
    '黎巴嫩': ['LB', '黎巴嫩', 'foreign'],
    '阿联酋': ['AE', '阿联酋', 'foreign'],
    '卡塔尔': ['QA', '卡塔尔', 'foreign'],
    '蒙古': ['MN', '蒙古', 'foreign'],

    // 欧洲 (foreign)
    '英': ['GB', '英国', 'foreign'],
    '英国': ['GB', '英国', 'foreign'],
    '德': ['DE', '德国', 'foreign'],
    '德国': ['DE', '德国', 'foreign'],
    '法': ['FR', '法国', 'foreign'],
    '法国': ['FR', '法国', 'foreign'],
    '俄': ['RU', '俄罗斯', 'foreign'],
    '俄罗斯': ['RU', '俄罗斯', 'foreign'],
    '苏': ['RU', '苏联', 'foreign'],
    '苏联': ['RU', '苏联', 'foreign'],
    '意': ['IT', '意大利', 'foreign'],
    '意大利': ['IT', '意大利', 'foreign'],
    '西': ['ES', '西班牙', 'foreign'],
    '西班牙': ['ES', '西班牙', 'foreign'],
    '葡': ['PT', '葡萄牙', 'foreign'],
    '葡萄牙': ['PT', '葡萄牙', 'foreign'],
    '荷': ['NL', '荷兰', 'foreign'],
    '荷兰': ['NL', '荷兰', 'foreign'],
    '比': ['BE', '比利时', 'foreign'],
    '比利时': ['BE', '比利时', 'foreign'],
    '瑞典': ['SE', '瑞典', 'foreign'],
    '瑞士': ['CH', '瑞士', 'foreign'],
    '芬': ['FI', '芬兰', 'foreign'],
    '芬兰': ['FI', '芬兰', 'foreign'],
    '挪威': ['NO', '挪威', 'foreign'],
    '丹麦': ['DK', '丹麦', 'foreign'],
    '波兰': ['PL', '波兰', 'foreign'],
    '希': ['GR', '希腊', 'foreign'],
    '希腊': ['GR', '希腊', 'foreign'],
    '爱尔兰': ['IE', '爱尔兰', 'foreign'],
    '奥': ['AT', '奥地利', 'foreign'],
    '奥地利': ['AT', '奥地利', 'foreign'],
    '捷克': ['CZ', '捷克', 'foreign'],
    '匈牙利': ['HU', '匈牙利', 'foreign'],
    '乌克兰': ['UA', '乌克兰', 'foreign'],
    '白俄罗斯': ['BY', '白俄罗斯', 'foreign'],
    '罗马尼亚': ['RO', '罗马尼亚', 'foreign'],
    '冰岛': ['IS', '冰岛', 'foreign'],
    '保加利亚': ['BG', '保加利亚', 'foreign'],
    '塞尔维亚': ['RS', '塞尔维亚', 'foreign'],
    '克罗地亚': ['HR', '克罗地亚', 'foreign'],

    // 大洋洲 (foreign)
    '澳': ['AU', '澳大利亚', 'foreign'],
    '澳大利亚': ['AU', '澳大利亚', 'foreign'],
    '新西兰': ['NZ', '新西兰', 'foreign'],

    // 非洲 (foreign)
    '埃及': ['EG', '埃及', 'foreign'],
    '南非': ['ZA', '南非', 'foreign'],
    '尼日��亚': ['NG', '尼日利亚', 'foreign'],
    '肯尼亚': ['KE', '肯尼亚', 'foreign'],
    '阿尔及利亚': ['DZ', '阿尔及利亚', 'foreign'],
    '摩洛哥': ['MA', '摩洛哥', 'foreign'],
    '埃塞俄比亚': ['ET', '埃塞俄比亚', 'foreign'],
  };

  /// 解析入口
  static ParsedBookAuthors parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const ParsedBookAuthors();
    }

    final text = raw.trim();
    final hasEtAl = text.contains('[等]') ||
        text.contains('... 等') ||
        text.contains('等著') ||
        text.contains('等人') ||
        text.contains('等编');

    final authors = <LibraryAuthorEntity>[];
    final originals = <LibraryAuthorEntity>[];
    final adapters = <LibraryAuthorEntity>[];
    final translators = <LibraryAuthorEntity>[];
    final editors = <LibraryAuthorEntity>[];
    final illustrators = <LibraryAuthorEntity>[];

    // 1. 判断是否使用显式标签 (如: "作者：xxx 译者：yyy")
    if (text.contains('作者：') ||
        text.contains('译者：') ||
        text.contains('原著：') ||
        text.contains('改编：') ||
        text.contains('作者:') ||
        text.contains('译者:')) {
      _parseLabeledString(
        text,
        authors: authors,
        originals: originals,
        adapters: adapters,
        translators: translators,
        editors: editors,
        illustrators: illustrators,
      );
    } else {
      // 2. 按分号分块 (超星多责任人的最通用分段方式)
      final sections = text.split(RegExp(r'[;；]'));
      if (sections.length > 1) {
        // 第一段通常是主要作者/原著者段，若其末尾包含了后面的次要责任人（如 "...著,张贝,袁萌"），
        // 需将其在第一段中多余列出的尾随姓名截断，避免与后面的分段重复
        final rightSection = sections.sublist(1).join(';');
        _parseFirstSectionWithTrailing(
          sections.first.trim(),
          rightSection,
          authors: authors,
          originals: originals,
          adapters: adapters,
          translators: translators,
          editors: editors,
          illustrators: illustrators,
        );

        for (int i = 1; i < sections.length; i++) {
          final sec = sections[i].trim();
          if (sec.isEmpty) continue;
          _parseSection(
            sec,
            authors: authors,
            originals: originals,
            adapters: adapters,
            translators: translators,
            editors: editors,
            illustrators: illustrators,
          );
        }
      } else {
        _parseSection(
          sections.first.trim(),
          authors: authors,
          originals: originals,
          adapters: adapters,
          translators: translators,
          editors: editors,
          illustrators: illustrators,
        );
      }
    }

    // 去重辅助：如果一个人已经作为译者/改编者/主编存在，则从主要 authors 中移除
    _deduplicateSecondary(
      authors: authors,
      originals: originals,
      secondary: [...translators, ...adapters, ...editors],
    );

    return ParsedBookAuthors(
      authors: authors,
      originals: originals,
      adapters: adapters,
      translators: translators,
      editors: editors,
      illustrators: illustrators,
      hasEtAl: hasEtAl,
    );
  }

  static void _deduplicateSecondary({
    required List<LibraryAuthorEntity> authors,
    required List<LibraryAuthorEntity> originals,
    required List<LibraryAuthorEntity> secondary,
  }) {
    final secNames = secondary.map((e) => e.name).toSet();
    authors.removeWhere((a) => secNames.contains(a.name));
  }

  static void _parseFirstSectionWithTrailing(
    String firstSec,
    String rightSections, {
    required List<LibraryAuthorEntity> authors,
    required List<LibraryAuthorEntity> originals,
    required List<LibraryAuthorEntity> adapters,
    required List<LibraryAuthorEntity> translators,
    required List<LibraryAuthorEntity> editors,
    required List<LibraryAuthorEntity> illustrators,
  }) {
    // 检查首段是否存在 "...著,张三,李四" 的情况
    // 匹配如 "著,"、"编著,"、"主编," 后的附带次要人员
    final roleSplit = RegExp(r'^(.*?)(著|原著|主编|编著|编)[,，、](.*)$');
    final match = roleSplit.firstMatch(firstSec);
    if (match != null) {
      final mainPart = '${match.group(1)}${match.group(2)}';
      _parseSection(
        mainPart,
        authors: authors,
        originals: originals,
        adapters: adapters,
        translators: translators,
        editors: editors,
        illustrators: illustrators,
      );
      return;
    }

    _parseSection(
      firstSec,
      authors: authors,
      originals: originals,
      adapters: adapters,
      translators: translators,
      editors: editors,
      illustrators: illustrators,
    );
  }

  static void _parseSection(
    String section, {
    required List<LibraryAuthorEntity> authors,
    required List<LibraryAuthorEntity> originals,
    required List<LibraryAuthorEntity> adapters,
    required List<LibraryAuthorEntity> translators,
    required List<LibraryAuthorEntity> editors,
    required List<LibraryAuthorEntity> illustrators,
  }) {
    var defaultRole = LibraryAuthorRole.author;
    if (section.contains('原著') || section.contains('原作')) {
      defaultRole = LibraryAuthorRole.original;
    } else if (section.contains('改编') ||
        section.contains('改写') ||
        section.contains('续写')) {
      defaultRole = LibraryAuthorRole.adapter;
    } else if (section.contains('译') || section.contains('翻译')) {
      defaultRole = LibraryAuthorRole.translator;
    } else if (section.contains('主编') ||
        section.contains('编著') ||
        section.contains('编') ||
        section.contains('整理') ||
        section.contains('注')) {
      defaultRole = LibraryAuthorRole.editor;
    } else if (section.contains('绘') ||
        section.contains('绘画') ||
        section.contains('插图')) {
      defaultRole = LibraryAuthorRole.illustrator;
    }

    // 括号正则：支持 (), （）, [], 【】
    final bracketReg = RegExp(r'[\(\[（【]([^\(\)\[\]（）【】]+)[\)\]）】]');

    // 清理 "... [等]" 标记
    var cleanSec = section
        .replaceAll(RegExp(r'\.{2,}\s*\[?等\]?'), '')
        .replaceAll('[等]', '')
        .trim();

    // 剔除前缀动词
    cleanSec = cleanSec.replaceAll(
      RegExp(r'^(原著|原作|作者|主编|编著|改编|改写|译者|主译|编者|编)\s*'),
      '',
    );

    // 拆分可能的多人 (带括号保护)
    final parts = _splitAuthorNames(cleanSec);

    for (final rawPart in parts) {
      if (rawPart.trim().isEmpty) continue;

      String? countryCode;
      String? countryName;
      bool isRegion = false;
      bool isAncient = false;
      String? originalName;

      // 提取括号内容
      final matches = bracketReg.allMatches(rawPart).toList();
      for (final m in matches) {
        final content = m.group(1)!.trim();
        if (_countryDb.containsKey(content)) {
          final info = _countryDb[content]!;
          countryCode = info[0];
          countryName = info[1];
          isRegion = info[2] == 'region';
          isAncient = info[2] == 'ancient';
        } else if (RegExp(r'^[a-zA-Z\s.,\-_]+$').hasMatch(content)) {
          // 纯英文字符/逗号 -> 原著名
          originalName = content;
        }
      }

      // 剥离括号与尾随动词
      var name = rawPart.replaceAll(bracketReg, '').trim();
      name = name
          .replaceAll(
            RegExp(r'(原著|原作|著|主编|编著|编|译|主译|绘|绘画|改编|改写|整理|撰集|撰)$'),
            '',
          )
          .trim();

      // 清洗西方学者姓名缩写，如 "普朗特的,L." 或 "普朗特的, L."
      final initialMatch =
          RegExp(r'^(.*?)(?:,\s*([A-Za-z](?:\.[A-Za-z])*\.?))$')
              .firstMatch(name);
      if (initialMatch != null) {
        name = initialMatch.group(1)!.trim();
        originalName ??= initialMatch.group(2)!.trim();
      }

      // 清洗 MARC 编目中的定语助词“的”，如“普朗特的” -> “普朗特”
      if (name.endsWith('的') && name.length > 2) {
        name = name.substring(0, name.length - 1);
      }

      // 如果由于只写了外文名导致 name 为空，回退到 originalName
      if (name.isEmpty && originalName != null) {
        name = originalName;
      }
      if (name.isEmpty) continue;

      final entity = LibraryAuthorEntity(
        name: name,
        originalName: originalName,
        countryCode: countryCode,
        countryName: countryName,
        isRegion: isRegion,
        isAncient: isAncient,
        role: defaultRole,
      );

      switch (defaultRole) {
        case LibraryAuthorRole.original:
          originals.add(entity);
          break;
        case LibraryAuthorRole.adapter:
          adapters.add(entity);
          break;
        case LibraryAuthorRole.translator:
          translators.add(entity);
          break;
        case LibraryAuthorRole.editor:
          editors.add(entity);
          break;
        case LibraryAuthorRole.illustrator:
          illustrators.add(entity);
          break;
        case LibraryAuthorRole.author:
          authors.add(entity);
          break;
      }
    }
  }

  static void _parseLabeledString(
    String text, {
    required List<LibraryAuthorEntity> authors,
    required List<LibraryAuthorEntity> originals,
    required List<LibraryAuthorEntity> adapters,
    required List<LibraryAuthorEntity> translators,
    required List<LibraryAuthorEntity> editors,
    required List<LibraryAuthorEntity> illustrators,
  }) {
    final regex = RegExp(
      r'(作者|原著|改编|译者|主编|编者)[:：]\s*([^作者|原著|改编|译者|主编|编者]+)',
    );
    for (final match in regex.allMatches(text)) {
      final label = match.group(1);
      final content = match.group(2)!.trim();

      var role = LibraryAuthorRole.author;
      if (label == '原著') role = LibraryAuthorRole.original;
      if (label == '改编') role = LibraryAuthorRole.adapter;
      if (label == '译者') role = LibraryAuthorRole.translator;
      if (label == '主编' || label == '编者') role = LibraryAuthorRole.editor;

      final dummyList = <LibraryAuthorEntity>[];
      _parseSection(
        content + _roleToSuffix(role),
        authors: authors,
        originals: originals,
        adapters: adapters,
        translators: translators,
        editors: editors,
        illustrators: dummyList,
      );
    }
  }

  static String _roleToSuffix(LibraryAuthorRole role) {
    switch (role) {
      case LibraryAuthorRole.original:
        return '原著';
      case LibraryAuthorRole.adapter:
        return '改编';
      case LibraryAuthorRole.translator:
        return '译';
      case LibraryAuthorRole.editor:
        return '编';
      default:
        return '著';
    }
  }

  /// 智能拆分人名（保留括号内��逗号）
  static List<String> _splitAuthorNames(String str) {
    // 保护形如 ",L." 或 ", L." 或 ",K.R." 的西文姓名首字母缩写中的逗号不被误切
    // 注意：只保护字母后带点（如 ", L."、", K. R."、",K.R."），不能把全名（如 ", Adrian Joliffe"）当成缩写！
    final protectedStr = str.replaceAllMapped(
      RegExp(r',(\s*[A-Za-z]\.(?:\s*[A-Za-z]\.)*)'),
      (m) => '__COMMA_INITIAL__${m.group(1)}',
    );
    final result = <String>[];
    final buffer = StringBuffer();
    int inBracket = 0;

    for (int i = 0; i < protectedStr.length; i++) {
      final char = protectedStr[i];
      if (char == '(' || char == '[' || char == '（' || char == '【') {
        inBracket++;
        buffer.write(char);
      } else if (char == ')' || char == ']' || char == '）' || char == '】') {
        if (inBracket > 0) inBracket--;
        buffer.write(char);
      } else if (inBracket == 0 &&
          (char == ',' || char == '，' || char == '、' || char == '/')) {
        final part = buffer.toString().trim();
        if (part.isNotEmpty) {
          result.add(part.replaceAll('__COMMA_INITIAL__', ','));
        }
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) {
      final part = buffer.toString().trim();
      if (part.isNotEmpty) {
        result.add(part.replaceAll('__COMMA_INITIAL__', ','));
      }
    }
    return result;
  }
}
