// Reuses the seek toast and centered preview layout pattern.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'recording_secondary_video.dart';

typedef RecordingSeekPreviewData = ({bool visible, int position, int total});

class RecordingSeekPreview extends StatelessWidget {
  const RecordingSeekPreview({
    super.key,
    required this.data,
    required this.fullscreen,
    required this.safeInsets,
    required this.controller,
  });

  final RecordingSeekPreviewData data;
  final bool fullscreen;
  final EdgeInsets safeInsets;
  final VideoController? controller;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedSwitcher(
            key: const ValueKey('recording-seek-preview'),
            duration: const Duration(milliseconds: 150),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            child: !data.visible
                ? const SizedBox.expand()
                : LayoutBuilder(builder: (context, constraints) {
              var height = fullscreen ? 108.0 : 81.0;
              final compatibleHeight = constraints.maxHeight - 140;
              if (compatibleHeight > 50) {
                height = math.min(height, compatibleHeight);
              }
              height = math.max(
                  0,
                  math.min(
                      height,
                      math.min(constraints.maxHeight,
                          constraints.maxWidth * 9 / 16)));
              const textStyle = TextStyle(color: Colors.white, fontSize: 12);
              return Stack(children: [
                Padding(
                  padding: EdgeInsets.only(top: safeInsets.top),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: FractionalTranslation(
                      translation: Offset(0, fullscreen ? 1.2 : .8),
                      child: Container(
                        key: const ValueKey('recording-seek-toast'),
                        decoration: const BoxDecoration(
                          color: Color(0x88000000),
                          borderRadius: BorderRadius.all(Radius.circular(64)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 2,
                          children: [
                            Text(_timestamp(data.position), style: textStyle),
                            const Text('/', style: textStyle),
                            Text(_timestamp(data.total), style: textStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (controller case final controller?)
                  Center(
                    child: ClipRRect(
                      key: const ValueKey('recording-seek-thumbnail'),
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: height,
                        width: height * 16 / 9,
                        // Existing drag previews seek both persistent players.
                        // Repaint the visible player's texture at thumbnail size;
                        // no extra decoder, network request or image encoding.
                        child: RecordingSecondaryVideo(controller: controller),
                      ),
                    ),
                  ),
              ]);
            }),
          ),
        ),
      );
}

String _timestamp(int seconds) {
  final minutes = (seconds ~/ 60) % 60;
  final tail = '${minutes.toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
  return seconds >= 3600 ? '${seconds ~/ 3600}:$tail' : tail;
}
