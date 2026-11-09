import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'recording_detail_sheet.dart';

class RecordingPlayerLayout extends StatefulWidget {
  const RecordingPlayerLayout({
    super.key,
    required this.video,
    required this.body,
    required this.expandedHeight,
    required this.topInset,
    required this.player,
    required this.canResume,
    required this.onResume,
    required this.onBack,
    this.tabBar,
    this.onMore,
    this.playingOverride,
    this.loading = false,
    this.onRefresh,
    this.detailScope,
  });

  final Widget video;
  final Widget body;
  final double expandedHeight;
  final double topInset;
  final Player? player;
  final bool canResume;
  final Future<void> Function() onResume;
  final VoidCallback onBack;
  final PreferredSizeWidget? tabBar;
  final VoidCallback? onMore;
  final bool? playingOverride;
  final bool loading;

  /// Pull-to-refresh for the nested content. Hosted here because the outer
  /// [NestedScrollView] consumes the drag until the video header collapses, so
  /// a refresh indicator inside the inner viewport would never start at the top.
  final Future<void> Function()? onRefresh;
  final Object? detailScope;

  @override
  State<RecordingPlayerLayout> createState() => _RecordingPlayerLayoutState();
}

class _RecordingPlayerLayoutState extends State<RecordingPlayerLayout> {
  final _scrollController = ScrollController();
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  bool _playing = false;
  bool _buffering = false;
  bool _expanding = false;
  Future<void>? _expandTask;
  Future<void>? _resumeTask;

  @override
  void initState() {
    super.initState();
    _bindPlayer();
  }

  @override
  void didUpdateWidget(RecordingPlayerLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) _bindPlayer();
    if (oldWidget.playingOverride != widget.playingOverride) {
      final playing =
          widget.playingOverride ?? widget.player?.state.playing ?? false;
      if (playing != _playing) {
        _playing = playing;
        if (playing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_expand());
          });
        }
      }
    }
    if (!oldWidget.canResume && widget.canResume && (_playing || _buffering)) {
      _expanding = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_expand().whenComplete(() {
          if (mounted) setState(() => _expanding = false);
        }));
      });
    }
    if (!oldWidget.loading && widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_expand());
      });
    }
  }

  void _bindPlayer() {
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    _playing = widget.playingOverride ?? widget.player?.state.playing ?? false;
    _buffering = widget.player?.state.buffering ?? false;
    _playingSubscription = widget.player?.stream.playing.listen((playing) {
      if (widget.playingOverride != null) return;
      if (!mounted || playing == _playing) return;
      setState(() => _playing = playing);
      if (playing) unawaited(_expand());
    });
    _bufferingSubscription =
        widget.player?.stream.buffering.listen((buffering) {
      if (!mounted || buffering == _buffering) return;
      setState(() => _buffering = buffering);
      if (buffering && widget.canResume) unawaited(_expand());
    });
    if (_playing || _buffering || widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_expand());
      });
    }
  }

  Future<void> _expand() {
    final pending = _expandTask;
    if (pending != null) return pending;
    if (!_scrollController.hasClients || _scrollController.offset <= 0) {
      return Future<void>.value();
    }
    setState(() => _expanding = true);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final position = _scrollController.position;
    late final Future<void> task;
    task = (disableAnimations
            ? Future<void>.sync(() => position.setPixels(0))
            : _animateHeader(position))
        .whenComplete(() {
      if (identical(_expandTask, task)) _expandTask = null;
      if (mounted) setState(() => _expanding = false);
    });
    _expandTask = task;
    return task;
  }

  Future<void> _animateHeader(ScrollPosition position) {
    final activity = DrivenScrollActivity(
      position as ScrollActivityDelegate,
      from: position.pixels,
      to: 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      vsync: position.context.vsync,
    );
    position.beginActivity(activity);
    return activity.done;
  }

  Future<void> _resume() {
    final pending = _resumeTask;
    if (pending != null) return pending;
    final player = widget.player;
    final canResume = widget.canResume;
    late final Future<void> task;
    task = _expand().then((_) async {
      if (mounted &&
          canResume &&
          widget.canResume &&
          identical(player, widget.player)) {
        await widget.onResume();
      }
    }).whenComplete(() {
      if (identical(_resumeTask, task)) _resumeTask = null;
    });
    _resumeTask = task;
    return task;
  }

  @override
  void dispose() {
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = math.max(kToolbarHeight, widget.expandedHeight);
    final tabHeight = widget.tabBar?.preferredSize.height ?? 0;
    final range = height - kToolbarHeight;
    final pinned =
        (widget.loading || (_playing || _buffering) && widget.canResume) &&
            !_expanding;
    // PiliPlus keeps the header's child stable while its render object handles
    // the scroll geometry (265f879fa85973b4bf885bde2562f1007f1013b8):
    // https://github.com/bggRGjQaUbCoE/PiliPlus/blob/265f879fa85973b4bf885bde2562f1007f1013b8/lib/common/widgets/sliver/video_header.dart
    // Keep our existing sliver geometry, but share one toolbar across delegate
    // rebuilds. Only its opacity and hit testing depend on the scroll offset.
    final collapsedToolbar = _RecordingCollapsedToolbar(
      canResume: widget.canResume,
      completed: widget.player?.state.completed ?? false,
      onResume: () => unawaited(_resume()),
      onBack: widget.onBack,
      onMore: widget.onMore,
    );
    // Scrolling only changes the status bar. Keep the nested viewport, tabs and
    // video subtree out of this listener's rebuilds; its sliver already receives
    // the collapse offset directly during layout.
    return AnimatedBuilder(
      animation: _scrollController,
      child: Expanded(
        child: Material(
            key: const ValueKey('recording-scroll-surface'),
            color: theme.colorScheme.surface,
            child: NestedScrollView(
              key: const ValueKey('recording-player-scroll'),
              controller: _scrollController,
              physics: const ClampingScrollPhysics(),
              headerSliverBuilder: (context, innerBoxIsScrolled) => [
                SliverOverlapAbsorber(
                    handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                        context),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _RecordingVideoHeader(
                        minExtent:
                            (pinned ? height : kToolbarHeight) + tabHeight,
                        maxExtent: height + tabHeight,
                        pinned: pinned,
                        video: widget.video,
                        tabBar: widget.tabBar,
                        collapsedToolbar: collapsedToolbar,
                      ),
                    )),
              ],
              body: widget.body,
            )),
      ),
      builder: (context, child) {
        final offset =
            _scrollController.hasClients ? _scrollController.offset : 0.0;
        final ratio =
            pinned || range <= 0 ? 0.0 : (offset / range).clamp(0.0, 1.0);
        final statusBrightness =
            ratio >= .5 ? theme.brightness : Brightness.dark;
        return RecordingDetailSheetHost(
          detailScope: widget.detailScope,
          topInset: widget.topInset + height - ratio * range,
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: statusBrightness == Brightness.dark
                  ? Brightness.light
                  : Brightness.dark,
              statusBarBrightness: statusBrightness,
            ),
            child: Column(children: [
              SizedBox(
                key: const ValueKey('recording-status-bar-inset'),
                width: double.infinity,
                height: widget.topInset,
                child: ColoredBox(
                  color: Color.lerp(
                      Colors.black, theme.colorScheme.surface, ratio)!,
                ),
              ),
              child!,
            ]),
          ),
        );
      },
    );
  }
}

class _RecordingVideoHeader extends SliverPersistentHeaderDelegate {
  _RecordingVideoHeader({
    required this.minExtent,
    required this.maxExtent,
    required this.pinned,
    required this.video,
    required this.tabBar,
    required this.collapsedToolbar,
  });

  @override
  final double minExtent;
  @override
  final double maxExtent;
  final bool pinned;
  final Widget video;
  final PreferredSizeWidget? tabBar;
  final Widget collapsedToolbar;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final tabHeight = tabBar?.preferredSize.height ?? 0;
    final videoHeight = maxExtent - tabHeight;
    final range = videoHeight - kToolbarHeight;
    final ratio =
        pinned || range <= 0 ? 0.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    return ClipRect(
      child: Column(children: [
        Expanded(
            child: ClipRect(
                key: const ValueKey('recording-player-header'),
                child: Stack(fit: StackFit.expand, children: [
                  IgnorePointer(
                    ignoring: ratio > 0,
                    child: ExcludeSemantics(
                      excluding: ratio > 0,
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: videoHeight,
                        maxHeight: videoHeight,
                        child: SizedBox(
                          height: videoHeight,
                          child: RepaintBoundary(child: video),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: ratio == 0,
                    child: ExcludeSemantics(
                      excluding: ratio == 0,
                      child: Opacity(
                        key: const ValueKey('recording-collapsed-toolbar'),
                        opacity: ratio,
                        child: collapsedToolbar,
                      ),
                    ),
                  ),
                ]))),
        if (tabBar != null)
          SizedBox(
            height: tabHeight,
            child: RepaintBoundary(child: tabBar),
          ),
      ]),
    );
  }

  @override
  bool shouldRebuild(_RecordingVideoHeader oldDelegate) =>
      minExtent != oldDelegate.minExtent ||
      maxExtent != oldDelegate.maxExtent ||
      pinned != oldDelegate.pinned ||
      video != oldDelegate.video ||
      tabBar != oldDelegate.tabBar ||
      collapsedToolbar != oldDelegate.collapsedToolbar;
}

class _RecordingCollapsedToolbar extends StatelessWidget {
  const _RecordingCollapsedToolbar({
    required this.canResume,
    required this.completed,
    required this.onResume,
    required this.onBack,
    required this.onMore,
  });

  final bool canResume;
  final bool completed;
  final VoidCallback onResume;
  final VoidCallback onBack;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            child: SizedBox(
              height: kToolbarHeight,
              child: Row(children: [
                IconButton(
                  tooltip: '返回课程列表',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: TextButton.icon(
                    key: const ValueKey('recording-resume-player'),
                    onPressed: onResume,
                    icon: Icon(canResume
                        ? completed
                            ? Icons.replay_rounded
                            : Icons.play_arrow_rounded
                        : Icons.expand_more),
                    label: Text(canResume
                        ? completed
                            ? '重新播放'
                            : '继续播放'
                        : '展开播放器'),
                  ),
                ),
                if (onMore != null)
                  IconButton(
                    key: const ValueKey('recording-collapsed-more'),
                    tooltip: '更多设置',
                    onPressed: onMore,
                    icon: const Icon(Icons.more_vert_outlined),
                  )
                else
                  const SizedBox(width: 48),
              ]),
            ),
          ),
        ),
      );
}
