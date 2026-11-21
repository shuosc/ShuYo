import 'package:flutter/widgets.dart';

/// The height check keeps landscape phones and short windows in compact mode.
bool usesExpandedLayout(BuildContext context) {
  final window = MediaQuery.sizeOf(context);
  return window.width >= 720 && window.height >= 640;
}
