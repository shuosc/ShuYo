import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

Route<T> shuyoRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  bool animated = true,
  // Deep links can appear immediately while keeping the normal back transition.
  bool animatePush = true,
}) {
  if (!animated) {
    return PageRouteBuilder<T>(
      settings: settings,
      fullscreenDialog: fullscreenDialog,
      opaque: true,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) {
        return _ShuYoRouteSurface(child: builder(context));
      },
    );
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return _ShuYoCupertinoRoute<T>(
      animatePush: animatePush,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
      builder: (context) => _ShuYoRouteSurface(child: builder(context)),
    );
  }
  return PageRouteBuilder<T>(
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    opaque: true,
    transitionDuration:
        animatePush ? const Duration(milliseconds: 240) : Duration.zero,
    reverseTransitionDuration: const Duration(milliseconds: 210),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _ShuYoRouteSurface(child: builder(context));
    },
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final begin = fullscreenDialog ? const Offset(0, 1) : const Offset(1, 0);
      final position = animation.drive(
        Tween<Offset>(begin: begin, end: Offset.zero).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ),
      );
      return SlideTransition(position: position, child: child);
    },
  );
}

// Keep the native back transition and interactive gesture handling even when
// a Widget deep link skips the push animation.
class _ShuYoCupertinoRoute<T> extends CupertinoPageRoute<T> {
  _ShuYoCupertinoRoute({
    required super.builder,
    required this.animatePush,
    super.settings,
    super.fullscreenDialog,
  });

  final bool animatePush;

  @override
  Duration get transitionDuration =>
      animatePush ? super.transitionDuration : Duration.zero;

  @override
  Duration get reverseTransitionDuration => super.transitionDuration;
}

class _ShuYoRouteSurface extends StatelessWidget {
  const _ShuYoRouteSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: child,
    );
  }
}
