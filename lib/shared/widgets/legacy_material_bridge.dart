import 'package:material_ui/material_ui.dart';

/// Shares the app's theme and locale with dependencies still using SDK Material.
///
/// Remove after table_calendar, flutter_markdown_plus and crop_your_image migrate.
class LegacyMaterialBridge extends StatelessWidget {
  const LegacyMaterialBridge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The official bridge is deprecated because it is a temporary migration API.
    // ignore: deprecated_member_use
    return MaterialUiCompatibilityBridge(child: child);
  }
}
