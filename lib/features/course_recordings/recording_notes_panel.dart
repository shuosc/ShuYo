import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../data/models/vod_ppt.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

/// The portrait player's lesson-specific, lazily built PPT notes stream.
class RecordingNotesPanel extends StatelessWidget {
  const RecordingNotesPanel({
    super.key,
    required this.slides,
    required this.loading,
    this.error,
    required this.onRefresh,
    required this.onSeek,
    this.headersLoader,
    this.nested = false,
    this.canSeek = true,
  });

  final List<VodPptSlide> slides;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final ValueChanged<Duration> onSeek;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final bool nested;
  final bool canSeek;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        key: const ValueKey('recording-notes-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        // Only visible attachments need image credentials and image decoding.
        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
        slivers: [
          if (nested)
            SliverLayoutBuilder(
              builder: (context, constraints) => SliverOverlapInjector(
                handle:
                    NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              ),
            ),
          if (loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                key: ValueKey('recording-notes-loading'),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在获取 PPT 笔记'),
                ]),
              ),
            )
          else if (error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                key: const ValueKey('recording-notes-error'),
                icon: Icons.cloud_off_outlined,
                title: 'PPT 笔记加载失败',
                message: error!,
              ),
            )
          else if (slides.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                key: ValueKey('recording-notes-empty'),
                icon: Icons.article_outlined,
                title: '当前课次暂无 PPT 笔记',
                message: '录播平台尚未提供这节课的 PPT 识别内容',
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('按时间排序',
                        style: ShuYoTextStyles.meta(
                            size: 13, color: colors.textSecondary)),
                    const SizedBox(height: 8),
                    Text(
                      '由录播平台识别 PPT 文字，可跳转播放对应内容。',
                      style: ShuYoTextStyles.meta(
                        color: colors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  12, 0, 8, MediaQuery.paddingOf(context).bottom + 24),
              sliver: SliverList.builder(
                itemCount: slides.length,
                itemBuilder: (context, index) => RepaintBoundary(
                  key: ValueKey('recording-note-${slides[index].id}'),
                  child: _NoteEntry(
                    slide: slides[index],
                    index: index,
                    onSeek: onSeek,
                    canSeek: canSeek,
                    headersLoader: headersLoader,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoteEntry extends StatelessWidget {
  const _NoteEntry({
    required this.slide,
    required this.index,
    required this.onSeek,
    required this.canSeek,
    required this.headersLoader,
  });

  final VodPptSlide slide;
  final int index;
  final ValueChanged<Duration> onSeek;
  final bool canSeek;
  final Future<Map<String, String>> Function(Uri)? headersLoader;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final position =
        slide.position < Duration.zero ? Duration.zero : slide.position;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ExcludeSemantics(
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${index + 1}'.padLeft(2, '0'),
                  style: ShuYoTextStyles.meta(
                    color: colors.textSecondary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PPT 第 ${index + 1} 页',
                    style: ShuYoTextStyles.meta(
                      size: 13,
                      color: colors.textSecondary,
                      weight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timestamp(position),
                    style: ShuYoTextStyles.meta(
                      size: 11,
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SelectableText(
                slide.text.isEmpty ? '这页暂未识别出文字' : slide.text,
                key: ValueKey('recording-note-text-${slide.id}'),
                style: ShuYoTextStyles.bodyCompact(
                  size: 14,
                  color: colors.textPrimary,
                  height: 1.75,
                ),
              ),
              if (slide.imageUrl case final url?) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Material(
                        color: colors.surfaceMuted,
                        child: InkWell(
                          key: ValueKey('recording-note-image-${slide.id}'),
                          onTap: () => _showPreview(context, url),
                          child: Semantics(
                            button: true,
                            label: '查看第 ${index + 1} 页 PPT 大图',
                            child: _PptImage(
                              url: url,
                              headersLoader: headersLoader,
                              cacheWidth: 660,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                TextButton.icon(
                  key: ValueKey('recording-note-seek-${slide.id}'),
                  onPressed: canSeek ? () => onSeek(position) : null,
                  style: _actionStyle(context),
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('跳转播放'),
                ),
                TextButton.icon(
                  key: ValueKey('recording-note-copy-${slide.id}'),
                  onPressed: slide.text.isEmpty ? null : () => _copy(context),
                  style: _actionStyle(context),
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  label: const Text('复制'),
                ),
              ]),
              const SizedBox(height: 5),
              Divider(
                  height: .3,
                  thickness: .3,
                  color: colors.textSecondary.withValues(alpha: .08)),
            ],
          ),
        ),
      ]),
    );
  }

  ButtonStyle _actionStyle(BuildContext context) => TextButton.styleFrom(
        foregroundColor: context.shuyoColors.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: ShuYoTextStyles.meta(size: 12),
      );

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: slide.text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制 PPT 笔记')),
    );
  }

  void _showPreview(BuildContext context, Uri url) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 960,
          height: MediaQuery.sizeOf(context).height * .75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(children: [
                Expanded(child: Text('PPT 第 ${index + 1} 页')),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ]),
            ),
            Expanded(
              child: ClipRect(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(
                    child: _PptImage(
                      url: url,
                      headersLoader: headersLoader,
                      cacheWidth: 1600,
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

String _timestamp(Duration position) {
  final seconds = position.inSeconds;
  final minutes = (seconds ~/ 60) % 60;
  final tail = '${minutes.toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
  return seconds >= 3600 ? '${seconds ~/ 3600}:$tail' : tail;
}

/// Obtains headers only when an attachment is built. FutureBuilder also ignores
/// completions for an old URL after a lesson changes or the row is disposed.
class _PptImage extends StatefulWidget {
  const _PptImage({
    required this.url,
    required this.headersLoader,
    required this.cacheWidth,
  });

  final Uri url;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final int cacheWidth;

  @override
  State<_PptImage> createState() => _PptImageState();
}

class _PptImageState extends State<_PptImage> {
  Future<Map<String, String>>? _headers;

  @override
  void initState() {
    super.initState();
    _loadHeaders();
  }

  @override
  void didUpdateWidget(covariant _PptImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.headersLoader != widget.headersLoader) {
      _loadHeaders();
    }
  }

  void _loadHeaders() {
    final loader = widget.headersLoader;
    _headers = loader == null ? null : Future.sync(() => loader(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    if (_headers == null) return _image(const {});
    return FutureBuilder<Map<String, String>>(
      future: _headers,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        if (snapshot.hasError) return _unavailable();
        return _image(snapshot.data ?? const {});
      },
    );
  }

  Widget _image(Map<String, String> headers) => Image.network(
        widget.url.toString(),
        headers: headers,
        fit: BoxFit.contain,
        cacheWidth: widget.cacheWidth,
        excludeFromSemantics: true,
        errorBuilder: (context, error, stackTrace) => _unavailable(),
        frameBuilder: (context, child, frame, synchronouslyLoaded) =>
            synchronouslyLoaded || frame != null
                ? child
                : const Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
      );

  Widget _unavailable() => Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'PPT 预览暂不可用',
            textAlign: TextAlign.center,
            style: ShuYoTextStyles.meta(
              color: context.shuyoColors.textMuted,
            ),
          ),
        ),
      );
}
