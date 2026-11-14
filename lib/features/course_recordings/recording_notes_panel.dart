import 'dart:async';

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
    required this.onSeek,
    this.headersLoader,
    this.nested = false,
    this.canSeek = true,
    this.isLive = false,
  });

  final List<VodPptSlide> slides;
  final bool loading;
  final String? error;
  final ValueChanged<Duration> onSeek;
  final Future<Map<String, String>> Function(Uri)? headersLoader;
  final bool nested;
  final bool canSeek;
  final bool isLive;

  @override
  State<RecordingNotesPanel> createState() => _RecordingNotesPanelState();
}

class _RecordingNotesPanelState extends State<RecordingNotesPanel> {
  static const _thumbnailCacheWidth = 312;

  late _PptImageHeaders _imageHeaders = _PptImageHeaders(widget.headersLoader);
  final _scrollController = ScrollController();
  final _animatedNotes = <String>{};
  final _failedThumbnails = <Uri>{};
  int _preloadGeneration = 0;
  bool _thumbnailsReady = true;
  bool _hasDependencies = false;

  final _preloadedKeepAlive = <ImageStreamCompleterHandle>[];

  @override
  void initState() {
    super.initState();
    _prepareThumbnails();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasDependencies) {
      _hasDependencies = true;
      if (!_thumbnailsReady) {
        unawaited(_preloadAllThumbnails(_preloadGeneration));
      }
    }
  }

  @override
  void didUpdateWidget(RecordingNotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.slides, widget.slides) ||
        oldWidget.headersLoader != widget.headersLoader ||
        oldWidget.loading != widget.loading ||
        oldWidget.isLive != widget.isLive) {
      if (!identical(oldWidget.slides, widget.slides) ||
          oldWidget.headersLoader != widget.headersLoader) {
        _imageHeaders = _PptImageHeaders(widget.headersLoader);
        _animatedNotes.clear();
        _failedThumbnails.clear();
        _releasePreloadedKeepAlive();
      }
      _prepareThumbnails();
      if (_hasDependencies && !_thumbnailsReady) {
        unawaited(_preloadAllThumbnails(_preloadGeneration));
      }
    }
  }

  @override
  void dispose() {
    _preloadGeneration++;
    _releasePreloadedKeepAlive();
    _scrollController.dispose();
    super.dispose();
  }

  void _releasePreloadedKeepAlive() {
    for (final handle in _preloadedKeepAlive) {
      handle.dispose();
    }
    _preloadedKeepAlive.clear();
  }

  void _prepareThumbnails() {
    _preloadGeneration++;
    final urls = _thumbnailUrls();
    if (widget.loading ||
        widget.isLive ||
        widget.error != null ||
        urls.isEmpty) {
      _thumbnailsReady = true;
      return;
    }
    _thumbnailsReady = false;
  }

  List<Uri> _thumbnailUrls() => [
        for (final slide in widget.slides)
          if (slide.imageUrl case final url?) url,
      ];

  Future<void> _preloadAllThumbnails(int generation) async {
    final urls = _thumbnailUrls();
    if (urls.isEmpty) {
      if (mounted && generation == _preloadGeneration && !_thumbnailsReady) {
        setState(() => _thumbnailsReady = true);
      }
      return;
    }
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final decodeWidth = (104 * dpr).ceil().clamp(1, _thumbnailCacheWidth);
    const concurrency = 6;
    var nextIndex = 0;
    Future<void> worker() async {
      while (mounted &&
          generation == _preloadGeneration &&
          nextIndex < urls.length) {
        final url = urls[nextIndex++];
        await _preloadThumbnail(url, decodeWidth, generation);
      }
    }

    final work = Future.wait<void>([
      for (var i = 0; i < concurrency && i < urls.length; i++) worker(),
    ]);
    // Do not keep the notes panel indefinitely blocked if a CDN thumbnail hangs.
    await work.timeout(const Duration(seconds: 6), onTimeout: () => const []);
    if (mounted && generation == _preloadGeneration) {
      setState(() => _thumbnailsReady = true);
    }
  }

  Future<void> _preloadThumbnail(
      Uri url, int decodeWidth, int generation) async {
    final Map<String, String> headers;
    try {
      headers = await _imageHeaders.load(url);
    } on Object {
      if (mounted && generation == _preloadGeneration) {
        _failedThumbnails.add(url);
      }
      return;
    }
    if (!mounted || generation != _preloadGeneration) return;
    _failedThumbnails.remove(url);
    final provider = ResizeImage(
      NetworkImage(url.toString(), headers: headers),
      width: decodeWidth,
    );
    // Only treat preloading as failed if header fetching itself throws;
    // image decode errors still let Image.network try/render its errorBuilder
    // and keep ResizeImage inspectable for tests and diagnostics.
    try {
      await _precacheProvider(provider, generation);
    } on Object {
      // Allow Image.network to attempt or handle image-level fallback cleanly.
    }
  }

  Future<void> _precacheProvider(ImageProvider provider, int generation) {
    final completer = Completer<void>();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        final keepAlive = stream.completer?.keepAlive();
        stream.removeListener(listener);
        if (keepAlive != null) {
          if (mounted && generation == _preloadGeneration) {
            _preloadedKeepAlive.add(keepAlive);
          } else {
            keepAlive.dispose();
          }
        }
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLoading =
        (widget.loading || (widget.error == null && !_thumbnailsReady)) &&
            !widget.isLive;
    final scroll = CustomScrollView(
      key: const ValueKey('recording-notes-scroll'),
      controller: widget.nested ? null : _scrollController,
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
        if (effectiveLoading)
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
              itemBuilder: (context, index) {
                final slide = widget.slides[index];
                final firstAppearance = _animatedNotes.add(slide.id);
                final primaryScroll = widget.nested
                    ? PrimaryScrollController.maybeOf(context)
                    : _scrollController;
                final scrolling = (primaryScroll?.hasClients ?? false) &&
                    primaryScroll!.position.isScrollingNotifier.value;
                return RepaintBoundary(
                  key: ValueKey('recording-note-${slide.id}'),
                  child: _NoteEntrance(
                    index: index,
                    animate: firstAppearance && !scrolling,
                    child: _NoteEntry(
                      slide: slide,
                      index: index,
                      total: widget.slides.length,
                      onSeek: widget.onSeek,
                      canSeek: widget.canSeek,
                      imageHeaders: _imageHeaders,
                      failedThumbnails: _failedThumbnails,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
    // Pull-to-refresh is intentionally absent: notes arrive with the lesson and
    // the containing player keeps the catalog current on its own.
    return RecordingDetailSheet.maybeOf(context) == null
        ? RecordingDetailSheetHost(topInset: 0, child: scroll)
        : scroll;
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
    required this.failedThumbnails,
  });

  final VodPptSlide slide;
  final int index;
  final int total;
  final ValueChanged<Duration> onSeek;
  final bool canSeek;
  final _PptImageHeaders imageHeaders;
  final Set<Uri> failedThumbnails;

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
                                    preloadedFailure:
                                        failedThumbnails.contains(url),
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
  });

  final Key labelKey;
  final int index;
  final int total;
  final Duration position;
  final TextStyle style;

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
          TextSpan(
              text: '${index + 1}',
              style: pageStyle.copyWith(
                  color: Theme.of(context).colorScheme.primary)),
          TextSpan(
              text: '/$total 页  ',
              style:
                  pageStyle.copyWith(color: context.shuyoColors.textPrimary)),
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

/// Obtains headers when needed and decodes to the actual display size.
/// Compact card thumbnails are preloaded by [RecordingNotesPanel] before rows
/// slide in, so they render immediately without per-card spinners.
class _PptImage extends StatefulWidget {
  const _PptImage({
    required this.url,
    required this.imageHeaders,
    required this.cacheWidth,
    this.compact = false,
    this.preloadedFailure = false,
  });

  final Uri url;
  final _PptImageHeaders imageHeaders;

  /// Decode ceiling; the actual width follows the rendered size and DPR.
  final int cacheWidth;
  final bool compact;
  final bool preloadedFailure;

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
        oldWidget.imageHeaders != widget.imageHeaders ||
        oldWidget.preloadedFailure != widget.preloadedFailure) {
      _loadHeaders();
    }
  }

  void _loadHeaders() {
    if (widget.preloadedFailure) {
      _headers = null;
      return;
    }
    _headers = widget.imageHeaders.peek(widget.url) == null
        ? widget.imageHeaders.load(widget.url)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.preloadedFailure) return _unavailable();
    final ready = widget.imageHeaders.peek(widget.url);
    if (ready != null) return _image(ready);
    if (widget.compact) {
      // Preloading failed or timed out for this thumbnail; avoid showing a
      // separate per-card loading spinner inside the slid-in card.
      return _unavailable();
    }
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

  // Decode for the actual display size while respecting the ceiling; the
  // full-screen image viewer uses the source asset.
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
            frameBuilder: widget.compact
                ? null
                : (context, child, frame, synchronouslyLoaded) =>
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

class _NoteEntrance extends StatefulWidget {
  const _NoteEntrance({
    required this.index,
    required this.animate,
    required this.child,
  });

  final int index;
  final bool animate;
  final Widget child;

  @override
  State<_NoteEntrance> createState() => _NoteEntranceState();
}

class _NoteEntranceState extends State<_NoteEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController? _entrance = widget.animate
      ? AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )
      : null;
  late final Animation<Offset>? _position = _entrance
      ?.drive(CurveTween(curve: Curves.easeOutCubic))
      .drive(Tween(begin: const Offset(0.12, 0), end: Offset.zero));
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final entrance = _entrance;
    if (entrance == null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _timer?.cancel();
      entrance.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      if (widget.index == 0) {
        entrance.forward();
      } else {
        _timer = Timer(Duration(milliseconds: (widget.index % 6) * 55), () {
          if (mounted) entrance.forward();
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _entrance?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entrance = _entrance;
    if (entrance == null) return widget.child;
    return SlideTransition(
      position: _position!,
      child: FadeTransition(opacity: entrance, child: widget.child),
    );
  }
}
