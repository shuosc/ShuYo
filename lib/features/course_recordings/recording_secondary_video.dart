import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

class RecordingSecondaryVideo extends StatelessWidget {
  const RecordingSecondaryVideo(
      {super.key,
      required this.controller,
      this.aspectRatio,
      this.fit = BoxFit.contain});

  final VideoController controller;
  final double? aspectRatio;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: ValueListenableBuilder<PlatformVideoController?>(
          valueListenable: controller.notifier,
          builder: (context, output, child) => output == null
              ? const SizedBox.expand()
              : ValueListenableBuilder<int?>(
                  valueListenable: output.id,
                  builder: (context, texture, child) =>
                      ValueListenableBuilder<Rect?>(
                    valueListenable: output.rect,
                    builder: (context, rect, child) {
                      if (texture == null ||
                          rect == null ||
                          rect.width <= 1 ||
                          rect.height <= 1) {
                        return const SizedBox.expand();
                      }
                      return FittedBox(
                          fit: fit,
                          child: SizedBox(
                            width: aspectRatio == null
                                ? rect.width
                                : rect.height * aspectRatio!,
                            height: rect.height,
                            child: Texture(
                                textureId: texture,
                                filterQuality: FilterQuality.medium),
                          ));
                    },
                  ),
                ),
        ),
      );
}
