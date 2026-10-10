import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/repositories/shuyo_content_repository.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../../shared/widgets/fullscreen_image_page.dart';

@visibleForTesting
const shuyoTipImagePlaceholderKey = ValueKey('shuyo-tip-image-placeholder');

class ShuyoContentPage extends StatelessWidget {
  const ShuyoContentPage({
    super.key,
    required this.repository,
    this.initialKind = ShuyoContentKind.tips,
    this.isDemo = false,
  });

  final ShuyoContentRepository repository;
  final ShuyoContentKind initialKind;
  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialKind == ShuyoContentKind.tips ? 0 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('通知'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '使用提示'),
              Tab(text: '系统公告'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ContentList(
                kind: ShuyoContentKind.tips,
                repository: repository,
                isDemo: isDemo),
            _ContentList(
                kind: ShuyoContentKind.announcements,
                repository: repository,
                isDemo: isDemo),
          ],
        ),
      ),
    );
  }
}

class _ContentList extends StatefulWidget {
  const _ContentList({
    required this.kind,
    required this.repository,
    required this.isDemo,
  });

  final ShuyoContentKind kind;
  final ShuyoContentRepository repository;
  final bool isDemo;

  @override
  State<_ContentList> createState() => _ContentListState();
}

class _ContentListState extends State<_ContentList>
    with AutomaticKeepAliveClientMixin {
  late Future<ShuyoContentLoad> _future = widget.isDemo
      ? Future.value(const ShuyoContentLoad([]))
      : widget.repository.load(widget.kind);

  @override
  bool get wantKeepAlive => true;

  Future<void> _refresh() async {
    final future = widget.isDemo
        ? Future.value(const ShuyoContentLoad([]))
        : widget.repository.load(widget.kind);
    setState(() => _future = future);
    try {
      await future;
    } on Object {
      // FutureBuilder displays the retry state.
    }
  }

  void _openDetail(ShuyoContentItem item) {
    Navigator.of(context).push<void>(
      shuyoRoute(
          builder: (_) => ShuyoContentDetailPage(
                item: item,
                kind: widget.kind,
                baseUri: widget.repository.baseUri,
              )),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<ShuyoContentLoad>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            message: snapshot.error.toString(),
            action: TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          );
        }
        final loaded = snapshot.data!;
        return Column(
          children: [
            if (loaded.fromCache)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(loaded.message ?? '',
                    style: TextStyle(color: context.shuyoColors.textSecondary)),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: loaded.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 96),
                          EmptyState(
                            icon: widget.kind == ShuyoContentKind.tips
                                ? Icons.lightbulb_outline
                                : Icons.campaign_outlined,
                            title: '暂无${widget.kind.label}',
                            message: '下拉刷新',
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                        itemCount: loaded.items.length,
                        itemBuilder: (context, index) {
                          final item = loaded.items[index];
                          return _ContentTile(
                            key: ValueKey('${widget.kind.path}:${item.id}'),
                            item: item,
                            kind: widget.kind,
                            index: index,
                            onTap: () => _openDetail(item),
                          );
                        },
                        separatorBuilder: (context, index) =>
                            CustomBackgroundScope.maybeOf(context) != null
                                ? const SizedBox.shrink()
                                : Divider(
                                    height: 1,
                                    color: context.shuyoColors.border),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContentTile extends StatefulWidget {
  const _ContentTile({
    super.key,
    required this.item,
    required this.kind,
    required this.index,
    required this.onTap,
  });

  final ShuyoContentItem item;
  final ShuyoContentKind kind;
  final int index;
  final VoidCallback onTap;

  @override
  State<_ContentTile> createState() => _ContentTileState();
}

class _ContentTileState extends State<_ContentTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    _startEntrance();
  }

  void _startEntrance() {
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final preview = _preview(widget.item.content, widget.kind);
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
      child: FadeTransition(
        opacity: _entrance,
        child: InkWell(
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 148),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(widget.item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ShuYoTextStyles.title(
                              color: colors.textPrimary,
                              size: 16,
                              height: 1.26,
                              weight: FontWeight.w500,
                            )),
                        if (preview.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Text(preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textTertiary,
                                  fontSize: 14.5,
                                  height: 1.46,
                                )),
                          ),
                        if (widget.item.createdAt != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(_date(widget.item.createdAt),
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 12.5,
                                )),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.chevron_right, color: colors.textMuted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _preview(String content, ShuyoContentKind kind) {
  var text = content;
  if (kind == ShuyoContentKind.tips) {
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '[图片]');
    text = text.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'), (match) => match.group(1) ?? '');
    text = text.replaceAll(RegExp(r'[`*_#>]'), '');
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class ShuyoContentDetailPage extends StatelessWidget {
  const ShuyoContentDetailPage({
    super.key,
    required this.item,
    required this.kind,
    required this.baseUri,
  });

  final ShuyoContentItem item;
  final ShuyoContentKind kind;
  final Uri baseUri;

  Uri? _safeImage(Uri source) {
    final uri = baseUri.resolveUri(source);
    if (uri.scheme != 'https' ||
        uri.host != baseUri.host ||
        !RegExp(r'^/api/v1/tips/images/[0-9a-f-]{36}\.(png|jpg|webp)$')
            .hasMatch(uri.path)) {
      return null;
    }
    return uri;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(kind.label)),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
          children: [
            Text(item.title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _date(item.createdAt),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (kind == ShuyoContentKind.announcements)
              Text(item.content,
                  style: const TextStyle(fontSize: 16, height: 1.65))
            else
              MarkdownBody(
                data: item.content,
                selectable: true,
                imageBuilder: (uri, title, alt) {
                  final safe = _safeImage(uri);
                  if (safe == null) return const Text('图片地址不可用');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push<void>(
                        shuyoRoute(
                          builder: (_) =>
                              FullscreenImagePage(url: safe.toString()),
                        ),
                      ),
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            safe.toString(),
                            fit: BoxFit.cover,
                            cacheWidth: _imageDecodeWidth(context),
                            frameBuilder: (context, child, frame,
                                wasSynchronouslyLoaded) {
                              if (wasSynchronouslyLoaded || frame != null) {
                                return child;
                              }
                              final colors = context.shuyoColors;
                              return Container(
                                key: shuyoTipImagePlaceholderKey,
                                height: 180,
                                alignment: Alignment.center,
                                color: colors.surfaceAlt,
                                child: Icon(Icons.image_outlined,
                                    size: 22, color: colors.textMuted),
                              );
                            },
                            errorBuilder: (context, error, stack) {
                              final colors = context.shuyoColors;
                              return Container(
                                height: 120,
                                alignment: Alignment.center,
                                color: colors.surfaceAlt,
                                child: Text('图片加载失败',
                                    style:
                                        TextStyle(color: colors.textTertiary)),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
                onTapLink: (text, href, title) {
                  final uri = Uri.tryParse(href ?? '');
                  if (uri?.scheme == 'https') {
                    unawaited(
                        launchUrl(uri!, mode: LaunchMode.externalApplication));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  int _imageDecodeWidth(BuildContext context) {
    final logicalWidth = MediaQuery.sizeOf(context).width - 40;
    final pixels =
        (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
    return pixels < 1 ? 1 : pixels;
  }
}

String _date(DateTime? date) {
  if (date == null) return '';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
