import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../data/models/vod_ppt.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/fullscreen_image_page.dart';
import 'recording_detail_sheet.dart';
import 'recording_player_tabs.dart';

/// The portrait player's lesson-specific, lazily built PPT notes stream.
class RecordingNotesPanel extends StatefulWidget {
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
    this.isLive = false,
  });

  final List<VodPptSlide> slides;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final ValueChanged<Duration> onSeek;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final bool nested;
  final bool canSeek;
  final bool isLive;

  @override
  State<RecordingNotesPanel> createState() => _RecordingNotesPanelState();
}

class _RecordingNotesPanelState extends State<RecordingNotesPanel> {
  late _PptImageHeaders _imageHeaders = _PptImageHeaders(widget.headersLoader);

  @override
  void didUpdateWidget(RecordingNotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.slides, widget.slides) ||
        oldWidget.headersLoader != widget.headersLoader) {
      _imageHeaders = _PptImageHeaders(widget.headersLoader);
    }
  }

  Future<void> _refresh() async {
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() => _imageHeaders = _PptImageHeaders(widget.headersLoader));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scroll = CustomScrollView(
      key: const ValueKey('recording-notes-scroll'),
      physics: const AlwaysScrollableScrollPhysics(),
      // Prepare nearby rows before they enter the viewport without loading
      // every attachment; resolved headers survive rows leaving the viewport.
      scrollCacheExtent: const ScrollCacheExtent.pixels(300),
      slivers: [
        if (widget.nested)
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverOverlapInjector(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            ),
          ),
        if (widget.loading && !widget.isLive)
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
        else if (widget.error != null && !widget.isLive)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              key: const ValueKey('recording-notes-error'),
              icon: Icons.cloud_off_outlined,
              title: 'PPT 笔记加载失败',
              message: widget.error!,
            ),
          )
        else if (widget.slides.isEmpty || widget.isLive)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              key: const ValueKey('recording-notes-empty'),
              icon: Icons.article_outlined,
              title: '当前课次暂无 PPT 笔记',
              message: widget.isLive ? '直播没有笔记' : '录播平台尚未提供这节课的 PPT 识别内容',
            ),
          )
        else ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                16, 0, 16, MediaQuery.paddingOf(context).bottom + 24),
            sliver: SliverList.builder(
              // Rows already own their keyed paint boundary below.
              addRepaintBoundaries: false,
              itemCount: widget.slides.length,
              itemBuilder: (context, index) => RepaintBoundary(
                key: ValueKey('recording-note-${widget.slides[index].id}'),
                child: _NoteEntry(
                  slide: widget.slides[index],
                  index: index,
                  total: widget.slides.length,
                  onSeek: widget.onSeek,
                  canSeek: widget.canSeek,
                  imageHeaders: _imageHeaders,
                ),
              ),
            ),
          ),
        ],
      ],
    );
    final panel = widget.isLive
        ? scroll
        : RefreshIndicator(onRefresh: _refresh, child: scroll);
    return RecordingDetailSheet.maybeOf(context) == null
        ? RecordingDetailSheetHost(topInset: 0, child: panel)
        : panel;
  }
}

class _NoteEntry extends StatelessWidget {
  const _NoteEntry({
    required this.slide,
    required this.index,
    required this.total,
    required this.onSeek,
    required this.canSeek,
    required this.imageHeaders,
  });

  final VodPptSlide slide;
  final int index;
  final int total;
  final ValueChanged<Duration> onSeek;
  final bool canSeek;
  final _PptImageHeaders imageHeaders;

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _NotePositionLabel(
                    labelKey: ValueKey('recording-note-position-${slide.id}'),
                    index: index,
                    total: total,
                    position: _position,
                    style: ShuYoTextStyles.meta(
                        color: colors.textSecondary, size: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
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
                                    imageHeaders: imageHeaders,
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
                        child: Text(
                          _preview(slide.text),
                          key: ValueKey('recording-note-summary-${slide.id}'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: ShuYoTextStyles.bodyCompact(
                            size: 14,
                            color: colors.textPrimary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
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
    RecordingDetailSheet.of(context).show((close) => _NoteDetails(
          slide: slide,
          index: index,
          total: total,
          position: _position,
          imageHeaders: imageHeaders,
          onClose: close,
          onSeek: canSeek
              ? () {
                  if (context.mounted) onSeek(_position);
                }
              : null,
        ));
  }
}

class _NoteDetails extends StatelessWidget {
  const _NoteDetails({
    required this.slide,
    required this.index,
    required this.total,
    required this.position,
    required this.imageHeaders,
    required this.onSeek,
    required this.onClose,
  });

  final VodPptSlide slide;
  final int index;
  final int total;
  final Duration position;
  final _PptImageHeaders imageHeaders;
  final VoidCallback? onSeek;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: Column(
          key: ValueKey('recording-note-detail-${slide.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const ValueKey('recording-note-detail-toolbar'),
              height: 45,
              padding: const EdgeInsets.only(left: 12, right: 2),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor.withValues(alpha: .1),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _NotePositionLabel(
                        labelKey:
                            const ValueKey('recording-note-detail-position'),
                        index: index,
                        total: total,
                        position: position,
                        prefix: '笔记详情  ',
                        style:
                            RecordingPlayerTabs.labelStyleOf(context).copyWith(
                          color: colors.textPrimary,
                        )),
                  ),
                  _CopyNoteButton(slide: slide),
                  IconButton(
                    key: ValueKey('recording-note-seek-${slide.id}'),
                    tooltip: '跳转播放',
                    onPressed: onSeek,
                    constraints:
                        const BoxConstraints.tightFor(width: 40, height: 40),
                    padding: const EdgeInsets.all(8),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    constraints:
                        const BoxConstraints.tightFor(width: 40, height: 40),
                    padding: const EdgeInsets.all(8),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CustomScrollView(
                key: ValueKey('recording-note-detail-scroll-${slide.id}'),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverList.list(
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
                                      key: ValueKey(
                                          'recording-note-image-${slide.id}'),
                                      onTap: () =>
                                          Navigator.of(context).push<void>(
                                        shuyoRoute(
                                          builder: (_) => FullscreenImagePage(
                                            url: url.toString(),
                                            headersLoader: imageHeaders.loader,
                                          ),
                                        ),
                                      ),
                                      child: Semantics(
                                        button: true,
                                        label: '查看第 ${index + 1} 页 PPT 大图',
                                        child: _PptImage(
                                          url: url,
                                          imageHeaders: imageHeaders,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotePositionLabel extends StatelessWidget {
  const _NotePositionLabel({
    required this.labelKey,
    required this.index,
    required this.total,
    required this.position,
    required this.style,
    this.prefix = '',
  });

  final Key labelKey;
  final int index;
  final int total;
  final Duration position;
  final TextStyle style;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final pageStyle = style.copyWith(
      fontSize: (style.fontSize ?? 12) + 1,
      fontWeight: FontWeight.w600,
    );
    return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(children: [
            if (prefix.isNotEmpty)
              TextSpan(
                  text: prefix,
                  style: TextStyle(color: context.shuyoColors.textPrimary)),
            TextSpan(
                text: '${index + 1}',
                style: pageStyle.copyWith(
                    color: Theme.of(context).colorScheme.primary)),
            TextSpan(
                text: '/$total 页  ',
                style: pageStyle.copyWith(color: context.shuyoColors.textPrimary)),
            TextSpan(
                text: _timestamp(position),
                style: TextStyle(color: context.shuyoColors.textTertiary)),
          ]),
          key: labelKey,
          maxLines: 1,
          softWrap: false,
          style: style,
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
  Widget build(BuildContext context) => IconButton(
        key: ValueKey('recording-note-copy-${widget.slide.id}'),
        tooltip: _copied ? '已复制' : '复制原文',
        onPressed: widget.slide.text.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: widget.slide.text));
                if (mounted) setState(() => _copied = true);
              },
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: const EdgeInsets.all(8),
        icon:
            Icon(_copied ? Icons.check_rounded : Icons.copy_outlined, size: 20),
      );
}

String _preview(String text) {
  if (text.isEmpty) return '这页暂未识别出文字';
  final preview = String.fromCharCodes(text.runes.take(320));
  return preview.length < text.length ? '$preview…' : preview;
}

/// Scoped to the lesson panel. Row eviction does not repeat cookie reads, and
/// completed headers can be used synchronously without a one-frame spinner.
class _PptImageHeaders {
  _PptImageHeaders(this.loader);

  final Future<Map<String, String>> Function(Uri)? loader;
  final _resolved = <Uri, Map<String, String>>{};
  final _pending = <Uri, Future<Map<String, String>>>{};

  Map<String, String>? peek(Uri url) =>
      loader == null ? const {} : _resolved[url];

  Future<Map<String, String>> load(Uri url) {
    final ready = peek(url);
    if (ready != null) return Future.value(ready);
    return _pending.putIfAbsent(
      url,
      () => Future.sync(() => loader!(url)).then((headers) {
        final resolved = Map<String, String>.unmodifiable(headers);
        _resolved[url] = resolved;
        return resolved;
      }).whenComplete(() {
        _pending.remove(url);
      }),
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
    required this.imageHeaders,
    required this.cacheWidth,
    this.compact = false,
  });

  final Uri url;
  final _PptImageHeaders imageHeaders;

  /// Decode ceiling; the actual width follows the rendered size and DPR.
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
        oldWidget.imageHeaders != widget.imageHeaders) {
      _loadHeaders();
    }
  }

  void _loadHeaders() {
    _headers = widget.imageHeaders.peek(widget.url) == null
        ? widget.imageHeaders.load(widget.url)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.imageHeaders.peek(widget.url);
    if (ready != null) return _image(ready);
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

  // Like PiliPlus's NetworkImgLayer, decode for the actual display size:
  // https://github.com/bggRGjQaUbCoE/PiliPlus/blob/265f879fa85973b4bf885bde2562f1007f1013b8/lib/common/widgets/image/network_img_layer.dart
  // Keep the existing ceilings; the full-screen image viewer uses the source.
  Widget _image(Map<String, String> headers) => LayoutBuilder(
        builder: (context, constraints) {
          final cacheWidth = constraints.hasBoundedWidth
              ? (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(1, widget.cacheWidth)
              : widget.cacheWidth;
          return Image.network(
            widget.url.toString(),
            headers: headers,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
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
        },
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
