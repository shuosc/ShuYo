import 'package:material_ui/material_ui.dart';

import '../shuyo_text_styles.dart';
import '../theme/shuyo_theme.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({
    super.key,
    required this.title,
    required this.onNotification,
    this.showSettings = false,
    this.onSettings,
  });

  final String title;
  final VoidCallback onNotification;
  final bool showSettings;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: IconButton(
              tooltip: '通知',
              onPressed: onNotification,
              icon: const Icon(Icons.notifications_none),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShuYoTextStyles.headerTitle(color: colors.textPrimary),
              ),
            ),
          ),
          if (showSettings)
            IconButton(
              tooltip: '设置',
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
            )
          else
            const SizedBox(width: 48),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
