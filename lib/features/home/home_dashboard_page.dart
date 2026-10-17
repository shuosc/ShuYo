import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lunar/calendar/Lunar.dart';

import '../../shared/shuyo_text_styles.dart';
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
    this.onOpenLibraryBooking,
    required this.onOpenOtp,
    required this.todayCourseContent,
    required this.announcementContent,
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
  final VoidCallback? onOpenLibraryBooking;
  final VoidCallback onOpenOtp;
  final String todayCourseContent;
  final String announcementContent;
  final bool isDemo;

  static String? _sessionGreetingText;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 20),
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
        _HomeRow(
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
          trailing: isAcademicLoginCompleting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : const Icon(Icons.account_circle_outlined),
          onTap: isAcademicLoginCompleting ? null : onLogin,
        ),
        _HomeRow(
          icon: Icons.event,
          title: '今日课程',
          content: todayCourseContent,
          onTap: onOpenAcademicSystem,
        ),
        _HomeRow(
          icon: Icons.developer_board,
          title: '通知公告',
          content: announcementContent,
          onTap: onOpenAnnouncements,
        ),
        _HomeRow(
          icon: Icons.location_on,
          title: '空教室查询',
          content: '查询当前可用教室',
          onTap: onOpenEmptyClassroom,
        ),
        _HomeRow(
          icon: Icons.local_library_outlined,
          title: '图书馆预约',
          content: '预约场馆座位',
          onTap: onOpenLibraryBooking,
        ),
        _HomeRow(
          icon: Icons.password,
          title: '动态口令',
          content: '查看并复制 OTP 令牌',
          onTap: onOpenOtp,
        ),
      ],
    );
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

class _HomeRow extends StatelessWidget {
  const _HomeRow({
    required this.title,
    required this.content,
    this.icon,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String content;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final customBackground = CustomBackgroundScope.maybeOf(context) != null;
    return InkWell(
      onTap: onTap,
      splashFactory: customBackground ? NoSplash.splashFactory : null,
      overlayColor: customBackground
          ? const WidgetStatePropertyAll(Colors.transparent)
          : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 68),
        // Keep the content inset while the tap ripple spans the full width.
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: customBackground
            ? null
            : BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
        child: Row(
          children: [
            if (icon != null) ...[
              SizedBox(
                width: 40,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    icon,
                    color: colors.textSecondary,
                    size: 22,
                  ),
                ),
              ),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 16,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 13.5,
                      height: 1.46,
                    ),
                  ),
                ],
              ),
            ),
            trailing ?? const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
