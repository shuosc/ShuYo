import 'package:flutter/material.dart';

import 'shuyo_theme.dart';

Color courseColorForSeed(BuildContext context, String seed) {
  final palette = context.shuyoColors.schedulePalette;
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}
