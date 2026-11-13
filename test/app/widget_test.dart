import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shuyo/app/shuyo_app.dart';
import 'package:shuyo/shared/theme/shuyo_theme.dart';

void main() {
  testWidgets('app uses Chinese text editing actions', (tester) async {
    await tester.pumpWidget(const ShuYoApp());

    final context = tester.element(find.byType(Scaffold));
    final localizations = MaterialLocalizations.of(context);

    expect(localizations.cutButtonLabel, '剪切');
    expect(localizations.copyButtonLabel, '复制');
    expect(localizations.pasteButtonLabel, '粘贴');
    expect(localizations.selectAllButtonLabel, '全选');
  });

  testWidgets('app shows startup icon state', (tester) async {
    await tester.pumpWidget(const ShuYoApp());

    expect(find.byType(CircularProgressIndicator), findsNothing);
    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/icon_clear_blue.png',
    );
  });

  testWidgets('app uses the initial dark theme for startup loading',
      (tester) async {
    await tester.pumpWidget(
      const ShuYoApp(initialThemeId: ShuYoThemes.systemDarkId),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(
        (image.image as AssetImage).assetName, 'assets/images/icon_clear.png');
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFF0D0D0D),
    );
  });
}
