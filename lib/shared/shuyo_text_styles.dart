import 'package:material_ui/material_ui.dart';

class ShuYoTextStyles {
  const ShuYoTextStyles._();

  static const TextTheme theme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 22,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),
    displayMedium: TextStyle(
      fontSize: 20,
      height: 1.2,
      fontWeight: FontWeight.w600,
    ),
    displaySmall: TextStyle(
      fontSize: 19,
      height: 1.22,
      fontWeight: FontWeight.w600,
    ),
    headlineLarge: TextStyle(
      fontSize: 19,
      height: 1.22,
      fontWeight: FontWeight.w600,
    ),
    headlineMedium: TextStyle(
      fontSize: 17.5,
      height: 1.22,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: TextStyle(
      fontSize: 16.5,
      height: 1.24,
      fontWeight: FontWeight.w600,
    ),
    titleLarge: TextStyle(
      fontSize: 17,
      height: 1.25,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      fontSize: 15.5,
      height: 1.25,
      fontWeight: FontWeight.w500,
    ),
    titleSmall: TextStyle(
      fontSize: 14.5,
      height: 1.25,
      fontWeight: FontWeight.w500,
    ),
    bodyLarge: TextStyle(
      fontSize: 15.5,
      height: 1.46,
      fontWeight: FontWeight.w400,
    ),
    bodyMedium: TextStyle(
      fontSize: 14.5,
      height: 1.42,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontSize: 12.5,
      height: 1.35,
      fontWeight: FontWeight.w400,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w500,
    ),
    labelMedium: TextStyle(
      fontSize: 13,
      height: 1.2,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: TextStyle(
      fontSize: 12,
      height: 1.2,
      fontWeight: FontWeight.w500,
    ),
  );

  static TextStyle pageTitle({Color? color}) {
    return TextStyle(
      fontSize: 19,
      height: 1.22,
      fontWeight: FontWeight.w600,
      color: color,
    );
  }

  static TextStyle headerTitle({Color? color}) {
    return TextStyle(
      fontSize: 17.5,
      height: 1.22,
      fontWeight: FontWeight.w600,
      color: color,
    );
  }

  static TextStyle sectionTitle({Color? color}) {
    return TextStyle(
      fontSize: 15.5,
      height: 1.24,
      fontWeight: FontWeight.w600,
      color: color,
    );
  }

  static TextStyle title({
    Color? color,
    double size = 17,
    double height = 1.25,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }

  static TextStyle body({
    Color? color,
    double size = 15.5,
    double height = 1.46,
    FontWeight weight = FontWeight.w400,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }

  static TextStyle bodyCompact({
    Color? color,
    double size = 14.5,
    double height = 1.42,
    FontWeight weight = FontWeight.w400,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }

  static TextStyle meta({
    Color? color,
    double size = 12.5,
    double height = 1.3,
    FontWeight weight = FontWeight.w400,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }

  static TextStyle label({
    Color? color,
    double size = 13.5,
    double height = 1.2,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }

  static TextStyle chip({
    Color? color,
    double size = 12.5,
    double height = 1.15,
    FontWeight weight = FontWeight.w500,
  }) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color,
    );
  }
}
