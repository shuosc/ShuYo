import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

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
    this.playingOverride,
  });

  final Widget video;
  final Widget body;
  final double expandedHeight;
  final double topInset;
  final Player? player;
  final bool canResume;
  final Future<void> Function() onResume;
  final VoidCallback onBack;
  final bool? playingOverride;

  @override
  State<RecordingPlayerLayout> createState() => _RecordingPlayerLayoutState();
}

class _RecordingPlayerLayoutState extends State<RecordingPlayerLayout> {
  final _scrollController = ScrollController();
  StreamSubscription<bool>? _playingSubscription;
  bool _playing = false;
  bool _expanding = false;
  Future<void>? _expandTask;
  Future<void>? _resumeTask;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollChanged);
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
    if (!oldWidget.canResume && widget.canResume && _playing) {
      _expanding = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_expand().whenComplete(() {
          if (mounted) setState(() => _expanding = false);
        }));
      });
    }
  }

  void _bindPlayer() {
    unawaited(_playingSubscription?.cancel());
    _playing = widget.playingOverride ?? widget.player?.state.playing ?? false;
    _playingSubscription = widget.player?.stream.playing.listen((playing) {
      if (widget.playingOverride != null) return;
      if (!mounted || playing == _playing) return;
      setState(() => _playing = playing);
      if (playing) unawaited(_expand());
    });
    if (_playing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_expand());
      });
    }
  }

  void _scrollChanged() {
    if (mounted) setState(() {});
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
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = math.max(kToolbarHeight, widget.expandedHeight);
    final offset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    final range = height - kToolbarHeight;
    final pinned = _playing && widget.canResume && !_expanding;
    final ratio = pinned || range <= 0 ? 0.0 : (offset / range).clamp(0.0, 1.0);
    final statusBrightness = ratio >= .5 ? theme.brightness : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
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
              color:
                  Color.lerp(Colors.black, theme.colorScheme.surface, ratio)!),
        ),
        Expanded(
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
                          minExtent: pinned ? height : kToolbarHeight,
                          maxExtent: height,
                          pinned: pinned,
                          video: widget.video,
                          canResume: widget.canResume,
                          completed: widget.player?.state.completed ?? false,
                          onResume: () => unawaited(_resume()),
                          onBack: widget.onBack,
                        ),
                      )),
                ],
                body: widget.body,
              )),
        ),
      ]),
    );
  }
}

class _RecordingVideoHeader extends SliverPersistentHeaderDelegate {
  _RecordingVideoHeader({
    required this.minExtent,
    required this.maxExtent,
    required this.pinned,
    required this.video,
    required this.canResume,
    required this.completed,
    required this.onResume,
    required this.onBack,
  });

  @override
  final double minExtent;
  @override
  final double maxExtent;
  final bool pinned;
  final Widget video;
  final bool canResume;
  final bool completed;
  final VoidCallback onResume;
  final VoidCallback onBack;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - kToolbarHeight;
    final ratio =
        pinned || range <= 0 ? 0.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    return ClipRect(
      key: const ValueKey('recording-player-header'),
      child: Stack(fit: StackFit.expand, children: [
        IgnorePointer(
          ignoring: ratio > 0,
          child: ExcludeSemantics(
            excluding: ratio > 0,
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: maxExtent,
              maxHeight: maxExtent,
              child: SizedBox(height: maxExtent, child: video),
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
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Align(
                  alignment: Alignment.topCenter,
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
                      const SizedBox(width: 48),
                    ]),
                  ),
                ),
              ),
            ),
          ),
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
      canResume != oldDelegate.canResume ||
      completed != oldDelegate.completed ||
      onResume != oldDelegate.onResume ||
      onBack != oldDelegate.onBack;
}
