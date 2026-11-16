import 'package:material_ui/material_ui.dart';

import '../theme/shuyo_theme.dart';

class ShuYoLaunchSurface extends StatelessWidget {
  const ShuYoLaunchSurface({
    super.key,
    required this.theme,
  });

  final ShuYoThemeSpec theme;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: theme.colors.background,
      body: Center(
        child: Image.asset(
          _iconAsset,
          width: 112,
          height: 112,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  String get _iconAsset {
    if (theme.id == ShuYoThemes.defaultId) {
      return 'assets/images/icon_clear_blue.png';
    }
    if (theme.colors.brightness == Brightness.light) {
      return 'assets/images/icon_clear_black.png';
    }
    return 'assets/images/icon_clear.png';
  }
}
