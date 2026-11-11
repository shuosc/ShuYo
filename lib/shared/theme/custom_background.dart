import 'dart:io';

import 'package:flutter/material.dart';

import 'shuyo_theme.dart';

@immutable
class CustomBackground {
  const CustomBackground({
    required this.imagePath,
    required this.opacity,
    required this.background,
    required this.surface,
    required this.text,
    required this.accent,
  });

  final String imagePath;
  bool get hasPhoto => imagePath.isNotEmpty;
  // 0 hides the photo; 100 shows the photo without a color veil.
  final int opacity;
  final Color background;
  final Color surface;
  final Color text;
  final Color accent;

  CustomBackground copyWith({
    String? imagePath,
    int? opacity,
    Color? background,
    Color? surface,
    Color? text,
    Color? accent,
  }) =>
      CustomBackground(
        imagePath: imagePath ?? this.imagePath,
        opacity: opacity ?? this.opacity,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        text: text ?? this.text,
        accent: accent ?? this.accent,
      );

  CustomBackground withBackgroundColor(Color color) {
    final dark = color.computeLuminance() < 0.32;
    final nextSurface = Color.lerp(color, Colors.white, dark ? 0.09 : 0.12)!;
    return copyWith(
      background: color,
      surface: nextSurface,
    );
  }

  Map<String, Object> toJson() => {
        'imagePath': imagePath,
        'opacity': opacity,
        'background': background.toARGB32(),
        'surface': surface.toARGB32(),
        'text': text.toARGB32(),
        'accent': accent.toARGB32(),
      };

  static CustomBackground? fromJson(Map<String, dynamic> json) {
    final path = json['imagePath'];
    final storedOpacity = json['opacity'];
    final oldTransparency = json['transparency'];
    final int? opacity;
    if (storedOpacity is int) {
      opacity = storedOpacity;
    } else if (oldTransparency is int &&
        {0, 25, 50, 75, 100}.contains(oldTransparency)) {
      // The previous 55% base-color veil left only 45% of the image visible.
      opacity = ((100 - oldTransparency) * 0.45).round();
    } else {
      opacity = null;
    }
    final background = json['background'];
    final surface = json['surface'];
    final text = json['text'];
    final accent = json['accent'];
    if (path is! String ||
        opacity == null ||
        opacity < 0 ||
        opacity > 100 ||
        background is! int ||
        surface is! int ||
        text is! int ||
        accent is! int) {
      return null;
    }
    return CustomBackground(
      imagePath: path,
      opacity: opacity,
      background: Color(background),
      surface: Color(surface),
      text: Color(text),
      accent: Color(accent),
    );
  }

  static Future<CustomBackground> fromImage({
    required String imagePath,
    required ImageProvider provider,
  }) async {
    final scheme = await ColorScheme.fromImageProvider(provider: provider);
    return CustomBackground(
      imagePath: imagePath,
      opacity: 50,
      background: scheme.surface,
      surface: scheme.surfaceContainerLow,
      text: scheme.onSurface,
      accent: scheme.primary,
    );
  }

  static CustomBackground withoutPhoto(ShuYoColors colors) => CustomBackground(
        imagePath: '',
        opacity: 0,
        background: colors.background,
        surface: colors.surface,
        text: colors.textPrimary,
        accent: colors.accent,
      );

  ShuYoThemeSpec get theme {
    final brightness = background.computeLuminance() < 0.32
        ? Brightness.dark
        : Brightness.light;
    final base = ShuYoThemes.byId(brightness == Brightness.dark
            ? ShuYoThemes.systemDarkId
            : ShuYoThemes.defaultId)
        .colors;
    final onAccent = _contrastingText(accent);
    final secondaryText = Color.lerp(text, surface, 0.22)!;
    final surfaceAlt = Color.lerp(surface, background, 0.42)!;
    final accentSoft = Color.lerp(accent, surface, 0.85)!;
    return ShuYoThemeSpec(
      id: ShuYoThemes.customBackgroundId,
      name: '自定义主题',
      colors: base.copyWith(
        brightness: brightness,
        background: background,
        surface: surface,
        surfaceAlt: surfaceAlt,
        surfaceMuted: Color.lerp(surface, text, 0.1),
        border: Color.lerp(surface, text, 0.2),
        borderStrong: Color.lerp(surface, text, 0.32),
        textPrimary: text,
        textSecondary: secondaryText,
        textTertiary: text,
        textMuted: text,
        accent: accent,
        accentAlt: Color.lerp(accent, text, 0.24),
        accentSoft: accentSoft,
        largeAction: accent,
        onLargeAction: onAccent,
        onAccent: onAccent,
        onAccentSoft: _contrastingText(accentSoft),
        navSelected: text,
        navUnselected: secondaryText,
        selectedFill: accent,
        onSelectedFill: onAccent,
        chipFill: surfaceAlt,
        chipBorder: Color.lerp(surface, text, 0.2),
        listAuthor: text,
        detailAuthor: secondaryText,
        disabledFill: Color.lerp(surface, text, 0.12),
        inverseSurface: text,
        inverseOnSurface: surface,
        scheduleEmptyCell: const Color(0x29000000),
      ),
    );
  }

  static Color _contrastingText(Color color) =>
      color.computeLuminance() > 0.179 ? Colors.black : Colors.white;
}

class CustomBackgroundScope extends InheritedWidget {
  const CustomBackgroundScope({
    super.key,
    required this.settings,
    required super.child,
  });

  final CustomBackground? settings;

  static CustomBackground? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CustomBackgroundScope>()
      ?.settings;

  @override
  bool updateShouldNotify(CustomBackgroundScope oldWidget) =>
      settings != oldWidget.settings;
}

class CustomBackgroundFrame extends StatelessWidget {
  const CustomBackgroundFrame({
    super.key,
    required this.settings,
    required this.child,
  });

  final CustomBackground? settings;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomBackgroundScope(
        settings: settings,
        child: CustomBackgroundLayer(settings: settings, child: child),
      );
}

class CustomBackgroundLayer extends StatelessWidget {
  const CustomBackgroundLayer({
    super.key,
    required this.settings,
    required this.child,
    this.fallbackColor,
  });

  final CustomBackground? settings;
  final Widget child;
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
            child: _BackgroundPaint(
                settings: settings, fallbackColor: fallbackColor)),
        child,
      ],
    );
  }
}

class _BackgroundPaint extends StatelessWidget {
  const _BackgroundPaint({required this.settings, required this.fallbackColor});

  final CustomBackground? settings;
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    if (settings == null) {
      return ColoredBox(color: fallbackColor ?? Colors.transparent);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: settings.background),
        if (settings.hasPhoto && settings.opacity > 0)
          Image.file(
            File(settings.imagePath),
            opacity: AlwaysStoppedAnimation(settings.opacity / 100),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
      ],
    );
  }
}
