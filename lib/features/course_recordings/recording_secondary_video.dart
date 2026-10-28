import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class RecordingSecondaryVideo extends StatelessWidget {
  const RecordingSecondaryVideo(
      {super.key, required this.textureId, required this.videoRect});

  final ValueListenable<int?> textureId;
  final ValueListenable<Rect?> videoRect;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int?>(
        valueListenable: textureId,
        builder: (context, texture, child) => ValueListenableBuilder<Rect?>(
          valueListenable: videoRect,
          builder: (context, rect, child) {
            if (texture == null ||
                rect == null ||
                rect.width <= 0 ||
                rect.height <= 0) {
              return const SizedBox.expand();
            }
            return FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: rect.width,
                  height: rect.height,
                  child: Texture(
                      textureId: texture, filterQuality: FilterQuality.medium),
                ));
          },
        ),
      );
}
