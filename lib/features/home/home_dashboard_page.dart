import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lunar/calendar/Lunar.dart';

import '../../data/models/home_layout.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/theme/custom_background.dart';

class HomeDashboardPage extends StatelessWidget {
  const HomeDashboardPage({
    super.key,
    required this.hasAcademicAccount,
    this.academicSessionExpired = false,
    this.academicDisplayName,
    required this.isAcademicLoginCompleting,
    required this.onLogin,
    required this.onOpenAcademicSystem,
    required this.onOpenAnnouncements,
    required this.onOpenEmptyClassroom,
    this.onOpenCourseRecordings,
    this.onOpenLibraryBooking,
    this.onOpenCampusCard,
    this.onRefreshCampusCard,
    this.isCampusCardRefreshing = false,
    this.campusCardContent = '查询余额和消费记录',
    this.onOpenCampusMap,
    required this.onOpenOtp,
    required this.todayCourseContent,
    required this.announcementContent,
    this.layout,
    this.isDemo = false,
  });

  final bool hasAcademicAccount;
  final bool academicSessionExpired;
  final String? academicDisplayName;
  final bool isAcademicLoginCompleting;
  final VoidCallback onLogin;
  final VoidCallback onOpenAcademicSystem;
  final VoidCallback onOpenAnnouncements;
  final VoidCallback onOpenEmptyClassroom;
  final VoidCallback? onOpenCourseRecordings;
  final VoidCallback? onOpenLibraryBooking;
  final VoidCallback? onOpenCampusCard;
  final VoidCallback? onRefreshCampusCard;
  final bool isCampusCardRefreshing;
  final String campusCardContent;
  final VoidCallback? onOpenCampusMap;
  final VoidCallback onOpenOtp;
  final String todayCourseContent;
  final String announcementContent;
  final HomeLayout? layout;
  final bool isDemo;

  static String? _sessionGreetingText;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final customBackground = CustomBackgroundScope.maybeOf(context) != null;
    final background =
        customBackground ? Colors.transparent : colors.background;
    final groups = (layout ?? HomeLayout.defaults()).visibleGroups;
    final accountRow = _HomeRow(
      title: isAcademicLoginCompleting
          ? '正在完成校园登录'
          : hasAcademicAccount
              ? academicDisplayName?.isNotEmpty == true
                  ? '你好，$academicDisplayName！'
                  : '你好！'
              : academicSessionExpired
                  ? '重新登录'
                  : '立即登录',
      content: isAcademicLoginCompleting
          ? '正在获取课表...'
          : hasAcademicAccount
              ? _greeting()
              : academicSessionExpired
                  ? '登录已失效，请重新登录'
                  : '登录后同步个人数据',
      trailing: SizedBox(
        width: kMinInteractiveDimension,
        height: kMinInteractiveDimension,
        child: Center(
          child: isAcademicLoginCompleting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : const Icon(Icons.account_circle_outlined),
        ),
      ),
      onTap: isAcademicLoginCompleting ? null : onLogin,
    );
    return ColoredBox(
      key: const ValueKey('home-background'),
      color: background,
      child: ListView(
        key: const PageStorageKey('home-dashboard'),
        padding: const EdgeInsets.only(top: 6, bottom: 16),
        children: [
          if (isDemo) ...[
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: context.shuyoColors.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.shuyoColors.border),
              ),
              child: Text(
                '演示模式 · 本地静态数据，操作不会上传',
                style: TextStyle(
                  color: context.shuyoColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (groups.isEmpty)
            _HomeCard(
              key: const ValueKey('home-account'),
              children: [accountRow],
            ),
          for (var index = 0; index < groups.length; index++)
            _HomeCard(
              key: ValueKey('home-card:${groups[index].id}'),
              children: [
                if (index == 0) accountRow,
                for (final entry in groups[index].entries)
                  if (entry.isDivider)
                    Divider(
                      key: ValueKey(entry.key),
                      color: colors.borderStrong,
                      height: 1,
                      thickness: 0.2,
                      indent: 0,
                      endIndent: 0,
                    )
                  else
                    _moduleRow(entry.module!),
              ],
            ),
        ],
      ),
    );
  }

  Widget _moduleRow(HomeModule module) {
    final key = ValueKey('home-module:${module.id}');
    return switch (module) {
      HomeModule.todayCourse => _HomeRow(
          key: key,
          icon: Icons.event,
          title: module.title,
          content: todayCourseContent,
          onTap: onOpenAcademicSystem,
        ),
      HomeModule.campusCard => _HomeRow(
          key: key,
          icon: Icons.account_balance_wallet_outlined,
          title: module.title,
          content: campusCardContent,
          onTap: onOpenCampusCard,
          disableRipple: true,
          trailing: IconButton(
            tooltip: isCampusCardRefreshing ? '正在刷新校园卡余额' : '刷新校园卡余额',
            onPressed: isCampusCardRefreshing ? null : onRefreshCampusCard,
            style: const ButtonStyle(
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStatePropertyAll(Colors.transparent),
            ),
            icon: isCampusCardRefreshing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: '正在刷新校园卡余额',
                    ),
                  )
                : const Icon(Icons.refresh, size: 22),
          ),
        ),
      HomeModule.announcements => _HomeRow(
          key: key,
          icon: Icons.developer_board,
          title: module.title,
          content: announcementContent,
          onTap: onOpenAnnouncements,
        ),
      HomeModule.emptyClassroom => _HomeRow(
          key: key,
          icon: Icons.location_on,
          title: module.title,
          content: '查看可用教室',
          onTap: onOpenEmptyClassroom,
        ),
      HomeModule.courseRecordings => _HomeRow(
          key: key,
          icon: Icons.ondemand_video_outlined,
          title: module.title,
          content: '查看课程回放',
          onTap: onOpenCourseRecordings,
        ),
      HomeModule.libraryBooking => _HomeRow(
          key: key,
          icon: Icons.local_library_outlined,
          title: module.title,
          content: '预约场馆座位',
          onTap: onOpenLibraryBooking,
        ),
      HomeModule.campusMap => _HomeRow(
          key: key,
          icon: Icons.map_outlined,
          title: module.title,
          content: '查找校园地点',
          onTap: onOpenCampusMap,
        ),
      HomeModule.otp => _HomeRow(
          key: key,
          icon: Icons.password,
          title: module.title,
          content: '查看并复制 OTP 令牌',
          onTap: onOpenOtp,
        ),
    };
  }

  String _greeting() {
    final cached = _sessionGreetingText;
    if (cached != null) {
      return cached;
    }

    final now = DateTime.now();
    final special = _specialGreeting(now);
    if (special != null) {
      return _cacheGreeting(special);
    }

    final hour = now.hour;
    if (hour < 6) {
      return _cacheGreeting(_pick(const [
        '夜深了，记得休息',
        '披星戴月，也别忘了好好睡觉',
        '夜色渐深，明天又是崭新开始',
      ]));
    }
    if (hour < 11) {
      return _cacheGreeting(_pick(const [
        '早上好，今天也顺利',
        '一日之计在于晨',
        '学习与生活，此刻渐入佳境',
        '早安，有个好心情',
        '保持节奏，灵感正发生',
      ]));
    }
    if (hour < 14) {
      return _cacheGreeting(_pick(const [
        '快到中午啦',
        '忙碌过半，先好好吃顿午餐',
        '停下片刻，稍作休息',
      ]));
    }
    if (hour < 18) {
      return _cacheGreeting(_pick(const [
        '下午好，保持节奏',
        '下午的悠闲时光～',
      ]));
    }
    return _cacheGreeting(_pick(const [
      '晚上好，今天辛苦了',
      '忙碌一天，晚上放松一下',
      '晚风轻轻，愿你今晚好梦',
      '晚上好～',
    ]));
  }

  String _cacheGreeting(String greeting) {
    _sessionGreetingText = greeting;
    return greeting;
  }

  String? _specialGreeting(DateTime date) {
    final lunarGreeting = _lunarGreeting(date);
    if (lunarGreeting != null) {
      return lunarGreeting;
    }
    final key = '${date.month}-${date.day}';
    const specialGreetings = <String, List<String>>{
      '1-1': ['新年快乐，愿新岁胜旧年！🎉', '元气满满迎接新的一年！'],
      '2-14': ['愿你被温柔和快乐包围', '今天也要好好爱自己'],
      '3-8': ['祝你自在明媚，闪闪发光'],
      '5-1': ['劳动节快乐，愿努力都有收获！'],
      '6-1': ['儿童节快乐，愿你永远保有童心！'],
      '9-10': ['教师节快乐，为老师送上一份祝福吧！'],
      '10-1': ['盛世华诞，举国同庆'],
    };
    final greetings = specialGreetings[key];
    return greetings == null ? null : _pick(greetings);
  }

  String? _lunarGreeting(DateTime date) {
    final festivals = Lunar.fromDate(date).getFestivals();
    if (_hasFestival(festivals, '除夕')) {
      return _pick(const [
        '冬尽今宵促，年开明日长。',
        '残腊即又尽，东风应渐闻。',
      ]);
    }
    if (_hasFestival(festivals, '春节')) {
      return _pick(const [
        '爆竹声中一岁除，春风送暖入屠苏。',
        '不须迎向东郊去，春在千门万户中。',
        '松竹含新秋，轩窗有余清。',
        '愿得长如此，年年物候新。',
      ]);
    }
    if (_hasFestival(festivals, '端午')) {
      return _pick(const [
        '端午安康，愿岁岁常欢愉。',
        '彩线轻缠红玉臂，小符斜挂绿云鬟。',
      ]);
    }
    if (_hasFestival(festivals, '中秋')) {
      return _pick(const [
        '但愿人长久，千里共婵娟。',
        '海上生明月，天涯共此时。',
      ]);
    }
    if (_hasFestival(festivals, '清明')) {
      return _pick(const [
        '寄相思于草木，留期许在心间。',
        '燕子来时新社，梨花落后清明。',
      ]);
    }
    if (_hasFestival(festivals, '元宵')) {
      return _pick(const [
        '今年元夜时，月与灯依旧。',
        '东风夜放花千树，更吹落、星如雨。',
      ]);
    }
    return null;
  }

  bool _hasFestival(List<String> festivals, String name) {
    return festivals.any((festival) =>
        festival == name || festival == '$name节' || festival.contains(name));
  }

  String _pick(List<String> values) {
    return values[Random().nextInt(values.length)];
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final custom = CustomBackgroundScope.maybeOf(context) != null;
    final lightCard = !custom && colors.brightness == Brightness.light;
    final surface = custom
        ? colors.surface.withValues(alpha: 0.72)
        : lightCard
            ? const Color(0xFFFFFEFC)
            : colors.surface;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: surface,
      elevation: lightCard ? 0.5 : 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _HomeRow extends StatelessWidget {
  const _HomeRow({
    super.key,
    required this.title,
    required this.content,
    this.icon,
    this.trailing,
    this.onTap,
    this.disableRipple = false,
  });

  final String title;
  final String content;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool disableRipple;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final customBackground = CustomBackgroundScope.maybeOf(context) != null;
    final tile = ListTile(
      contentPadding: EdgeInsetsDirectional.only(
        start: 16,
        end: trailing == null ? 24 : 10,
      ),
      minVerticalPadding: 8,
      minLeadingWidth: 24,
      horizontalTitleGap: 16,
      leading: icon == null
          ? null
          : Icon(icon, size: 24, color: colors.textSecondary),
      titleTextStyle: TextStyle(
        color: colors.textPrimary,
        fontSize: 15.5,
        fontWeight: FontWeight.w500,
        height: 1.5,
        letterSpacing: 0.5,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        content,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: customBackground
              ? colors.textTertiary
              : Color.lerp(colors.textSecondary, colors.textTertiary, 0.7),
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.43,
          letterSpacing: 0.25,
        ),
      ),
      trailing: trailing,
      onTap: onTap,
    );
    if (!customBackground && !disableRipple) return tile;
    return Theme(
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
      ),
      child: tile,
    );
  }
}
