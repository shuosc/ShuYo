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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 16,
                      runSpacing: 6,
                      children: [
                        Text('共 ${slides.length} 条笔记',
                            style: ShuYoTextStyles.meta(
                                size: 13, color: colors.textSecondary)),
                        Text('按时间排序',
                            style: ShuYoTextStyles.meta(
                                color: colors.textTertiary)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '文字由录播平台自动识别，点击笔记查看全文。',
                      style: ShuYoTextStyles.meta(
                        color: colors.textTertiary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  16, 0, 16, MediaQuery.paddingOf(context).bottom + 24),
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

  Duration get _position =>
      slide.position < Duration.zero ? Duration.zero : slide.position;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('recording-note-open-${slide.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => _showDetails(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    key: ValueKey('recording-note-thumbnail-${slide.id}'),
                    width: 104,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColoredBox(
                          color: colors.surfaceMuted,
                          child: switch (slide.imageUrl) {
                            final url? => _PptImage(
                                url: url,
                                headersLoader: headersLoader,
                                cacheWidth: 312,
                                compact: true,
                              ),
                            null => Semantics(
                                label: '本条笔记暂无 PPT 截图',
                                child: Icon(Icons.slideshow_outlined,
                                    color: colors.textMuted, size: 28),
                              ),
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          slide.text.isEmpty ? '这页暂未识别出文字' : slide.text,
                          key: ValueKey('recording-note-summary-${slide.id}'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: ShuYoTextStyles.bodyCompact(
                            size: 14,
                            color: colors.textPrimary,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          children: [
                            Text('PPT 第 ${index + 1} 页',
                                style: ShuYoTextStyles.meta(
                                    color: colors.textSecondary, size: 12)),
                            Text(_timestamp(_position),
                                style: ShuYoTextStyles.meta(
                                    color: colors.textTertiary, size: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Divider(height: 1, thickness: .5, color: colors.border),
      ],
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.shuyoColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .8,
        child: _NoteDetails(
          slide: slide,
          index: index,
          position: _position,
          headersLoader: headersLoader,
          onSeek: canSeek
              ? () {
                  Navigator.pop(sheetContext);
                  if (context.mounted) onSeek(_position);
                }
              : null,
        ),
      ),
    );
  }
}

class _NoteDetails extends StatelessWidget {
  const _NoteDetails({
    required this.slide,
    required this.index,
    required this.position,
    required this.headersLoader,
    required this.onSeek,
  });

  final VodPptSlide slide;
  final int index;
  final Duration position;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final VoidCallback? onSeek;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SafeArea(
      top: false,
      child: Column(
        key: ValueKey('recording-note-detail-${slide.id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('笔记详情',
                          style: ShuYoTextStyles.sectionTitle(
                              color: colors.textPrimary)),
                      const SizedBox(height: 4),
                      Text('PPT 第 ${index + 1} 页 · ${_timestamp(position)}',
                          style: ShuYoTextStyles.meta(
                              color: colors.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: .5, color: colors.border),
          Expanded(
            child: ListView(
              key: ValueKey('recording-note-detail-scroll-${slide.id}'),
              padding: const EdgeInsets.all(16),
              children: [
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
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
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
                                  cacheWidth: 1280,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, thickness: .5, color: colors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 12,
              overflowSpacing: 4,
              children: [
                _CopyNoteButton(slide: slide),
                FilledButton.icon(
                  key: ValueKey('recording-note-seek-${slide.id}'),
                  onPressed: onSeek,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('定位播放'),
                ),
              ],
            ),
          ),
        ],
      ),
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

class _CopyNoteButton extends StatefulWidget {
  const _CopyNoteButton({required this.slide});

  final VodPptSlide slide;

  @override
  State<_CopyNoteButton> createState() => _CopyNoteButtonState();
}

class _CopyNoteButtonState extends State<_CopyNoteButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: ValueKey('recording-note-copy-${widget.slide.id}'),
        onPressed: widget.slide.text.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: widget.slide.text));
                if (mounted) setState(() => _copied = true);
              },
        icon:
            Icon(_copied ? Icons.check_rounded : Icons.copy_outlined, size: 18),
        label: Text(_copied ? '已复制' : '复制全文'),
      );
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
    this.compact = false,
  });

  final Uri url;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final int cacheWidth;
  final bool compact;

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

  Widget _unavailable() => widget.compact
      ? Semantics(
          label: 'PPT 预览暂不可用',
          child: Icon(Icons.broken_image_outlined,
              color: context.shuyoColors.textMuted, size: 26),
        )
      : Center(
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
