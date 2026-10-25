import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

class RecommendShuyoPage extends StatelessWidget {
  const RecommendShuyoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return DefaultTabController(
      length: _DownloadPlatform.values.length,
      child: Scaffold(
        appBar: AppBar(title: const Text('推荐ShuYo')),
        body: SafeArea(
          child: Builder(
            builder: (context) {
              final controller = DefaultTabController.of(context);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '感谢你愿意向朋友推荐 ShuYo！欢迎分享下方二维码，让更多同学用上 ShuYo。',
                          style: ShuYoTextStyles.bodyCompact(
                            color: colors.textMuted,
                            height: 1.55,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TabBar(
                          isScrollable: true,
                          tabAlignment: TabAlignment.center,
                          tabs: [
                            for (final platform in _DownloadPlatform.values)
                              Tab(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(platform.icon, size: 20),
                                    const SizedBox(width: 8),
                                    Text(platform.label),
                                  ],
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        AnimatedBuilder(
                          animation: controller,
                          builder: (context, _) => _DownloadQrCode(
                            platform:
                                _DownloadPlatform.values[controller.index],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _DownloadPlatform {
  android(
    label: 'Android',
    icon: Icons.android,
    url: 'https://download.shuyo.work/latest.apk',
    instruction: '使用 Android 设备扫码，下载并安装 APK。',
  ),
  apple(
    label: 'iOS/iPadOS',
    icon: Icons.apple,
    url: 'https://testflight.apple.com/join/aENUC3G3',
    instruction: 'iOS/iPadOS 版本通过 TestFlight 提供。'
        '请先从 App Store 安装 TestFlight，再扫码加入 ShuYo 测试并安装。',
  );

  const _DownloadPlatform({
    required this.label,
    required this.icon,
    required this.url,
    required this.instruction,
  });

  final String label;
  final IconData icon;
  final String url;
  final String instruction;
}

class _DownloadQrCode extends StatelessWidget {
  const _DownloadQrCode({required this.platform});

  final _DownloadPlatform platform;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // Keep dark modules on a light, opaque surface even with a dark or custom
    // theme. Derive both colors from the theme and tone down pale accents so
    // decorative styling does not reduce the code's scanning contrast.
    final palette = [
      colors.surface,
      colors.textPrimary,
      colors.accent,
      colors.onAccent,
    ].map((color) => color.withValues(alpha: 1)).toList()
      ..sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));
    final qrBackground = palette.last;
    var qrForeground = colors.accent.withValues(alpha: 1);
    for (var step = 1;
        step <= 10 &&
            (qrBackground.computeLuminance() + 0.05) /
                    (qrForeground.computeLuminance() + 0.05) <
                4.5;
        step++) {
      qrForeground = Color.lerp(colors.accent, palette.first, step / 10)!
          .withValues(alpha: 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 264),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: QrImageView(
                    data: platform.url,
                    errorCorrectionLevel: QrErrorCorrectLevel.H,
                    padding: const EdgeInsets.all(24),
                    backgroundColor: qrBackground,
                    gapless: false,
                    eyeStyle: QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: qrForeground,
                    ),
                    dataModuleStyle: QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.circle,
                      color: qrForeground,
                    ),
                    semanticsLabel: '${platform.label} 下载二维码：${platform.url}',
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          platform.url,
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.meta(color: colors.textMuted),
        ),
        const SizedBox(height: 20),
        Text(
          platform.instruction,
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.bodyCompact(
            color: colors.textSecondary,
            height: 1.55,
          ),
        ),
      ],
    );
  }
}
