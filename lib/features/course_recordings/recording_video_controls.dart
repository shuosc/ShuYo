import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import 'recording_playback_status.dart';
import 'recording_seek_controller.dart';
import 'recording_status_icon.dart';

class RecordingVideoControls extends StatefulWidget {
  const RecordingVideoControls({
    super.key,
    required this.state,
    required this.player,
    required this.title,
    required this.loading,
    required this.failure,
    required this.views,
    required this.selectedView,
    this.fullscreen = false,
    this.isLive = false,
    this.onReconnect,
    this.lessons = const [],
    this.selectedLessonId,
    this.onLessonSelected,
    this.onBack,
    this.dualEnabled = false,
    this.onDualChanged,
    this.secondaryView,
    this.secondaryLabel = '',
    this.onSwapViews,
    this.aspect = '自动',
    this.onAspectChanged,
    this.onEpisodePanelVisibilityChanged,
    this.onSeek,
    this.primaryView,
    this.onReload,
  });

  final VideoState state;
  final Player player;
  final String title;
  final bool loading;
  final Widget? failure;
  final List<VodView> views;
  final int selectedView;
  final bool fullscreen;
  final bool isLive;
  final VoidCallback? onReconnect;
  final List<VodLesson> lessons;
  final int? selectedLessonId;
  final ValueChanged<VodLesson>? onLessonSelected;
  final VoidCallback? onBack;
  final bool dualEnabled;
  final ValueChanged<bool>? onDualChanged;
  final Widget? secondaryView;
  final String secondaryLabel;
  final VoidCallback? onSwapViews;
  final String aspect;
  final ValueChanged<String>? onAspectChanged;
  final ValueChanged<bool>? onEpisodePanelVisibilityChanged;
  final Future<void> Function(Duration position)? onSeek;
  final Widget? primaryView;
  final VoidCallback? onReload;

  @override
  State<RecordingVideoControls> createState() => _RecordingVideoControlsState();
}

class _RecordingVideoControlsState extends State<RecordingVideoControls>
    with SingleTickerProviderStateMixin {
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final AnimationController _episodeAnimation;
  late RecordingSeekController _seekController;
  Timer? _hideTimer;
  bool _visible = true;
  bool _episodesOpen = false;
  double? _dragPosition;
  Offset? _floatingPosition;
  int _seekRevision = 0;

  @override
  void initState() {
    super.initState();
    _episodeAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) {
          widget.onEpisodePanelVisibilityChanged?.call(false);
          _showControls();
        }
      });
    _bindPlayer();
    _showControls();
  }

  void _bindPlayer() {
    _seekController = RecordingSeekController(
      seek: (position) =>
          widget.onSeek?.call(position) ?? widget.player.seek(position),
      onPreviewError: _reportSeekError,
    );
    for (final stream in <Stream<dynamic>>[
      widget.player.stream.position,
      widget.player.stream.duration,
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.buffer,
      widget.player.stream.rate,
    ]) {
      _subscriptions.add(stream.listen((_) {
        if (mounted) setState(() {});
      }));
    }
  }

  @override
  void didUpdateWidget(covariant RecordingVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _seekController.dispose();
      _seekRevision++;
      _dragPosition = null;
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      _bindPlayer();
    }
  }

  @override
  void dispose() {
    if (_episodePanelVisible) {
      widget.onEpisodePanelVisibilityChanged?.call(false);
    }
    _hideTimer?.cancel();
    _seekController.dispose();
    _episodeAnimation.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  bool get _episodePanelVisible => _episodesOpen || _episodeAnimation.value > 0;

  void _beginSeek(double value) {
    _seekRevision++;
    _seekController.begin();
    _hideTimer?.cancel();
    setState(() => _dragPosition = value);
  }

  void _previewSeek(double value) {
    _hideTimer?.cancel();
    setState(() => _dragPosition = value);
    _seekController.preview(Duration(milliseconds: value.round()));
  }

  Future<void> _finishSeek(double value) async {
    final revision = ++_seekRevision;
    setState(() => _dragPosition = value);
    try {
      await _seekController.finish(Duration(milliseconds: value.round()));
    } catch (error, stack) {
      _reportSeekError(error, stack);
    } finally {
      if (mounted && revision == _seekRevision) {
        setState(() => _dragPosition = null);
        _showControls();
      }
    }
  }

  void _reportSeekError(Object error, StackTrace stack) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'course recordings',
      context: ErrorDescription('while seeking the recording'),
    ));
  }

  void _openEpisodes() {
    _hideTimer?.cancel();
    widget.onEpisodePanelVisibilityChanged?.call(true);
    setState(() => _episodesOpen = true);
    unawaited(_episodeAnimation.forward());
  }

  void _closeEpisodes() {
    setState(() => _episodesOpen = false);
    unawaited(_episodeAnimation.reverse());
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _visible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          widget.player.state.playing &&
          _dragPosition == null &&
          !_episodesOpen) {
        setState(() => _visible = false);
      }
    });
  }

  void _togglePlayback() {
    if (widget.loading || widget.failure != null) return;
    if (widget.isLive &&
        !widget.player.state.playing &&
        widget.onReconnect != null) {
      widget.onReconnect!();
    } else {
      unawaited(widget.player.playOrPause());
    }
    _showControls();
  }

  VodLesson? _adjacentLesson(int direction) {
    final index = widget.lessons
        .indexWhere((lesson) => lesson.id == widget.selectedLessonId);
    if (index < 0) return null;
    for (var candidate = index + direction;
        candidate >= 0 && candidate < widget.lessons.length;
        candidate += direction) {
      if (widget.lessons[candidate].canPlay) return widget.lessons[candidate];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = widget.fullscreen;
    return PopScope(
      canPop: !_episodePanelVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _episodesOpen) _closeEpisodes();
      },
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: LayoutBuilder(builder: (context, constraints) {
            return GestureDetector(
              key: const ValueKey('recording-control-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  _visible ? setState(() => _visible = false) : _showControls(),
              onDoubleTap: _togglePlayback,
              child: Stack(children: [
                if (widget.primaryView != null)
                  Positioned.fill(
                      child: IgnorePointer(child: widget.primaryView!)),
                if (fullscreen &&
                    widget.dualEnabled &&
                    widget.views.length > 1 &&
                    widget.secondaryView != null)
                  _floatingView(constraints),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_visible || _episodePanelVisible,
                    child: AnimatedOpacity(
                      key: const ValueKey('recording-controls-overlay'),
                      opacity: _visible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Stack(children: [
                        Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            decoration: _gradient(top: true),
                            padding: EdgeInsets.symmetric(
                                horizontal: fullscreen ? 10 : 4,
                                vertical: fullscreen ? 10 : 4),
                            child: SafeArea(
                              bottom: false,
                              top: fullscreen,
                              child: Row(children: [
                                IconButton(
                                  tooltip: fullscreen ? '退出全屏' : '返回课程列表',
                                  onPressed: fullscreen
                                      ? () => unawaited(
                                          widget.state.exitFullscreen())
                                      : widget.onBack,
                                  icon: const Icon(Icons.arrow_back,
                                      color: Colors.white, size: 24),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                      width: 40, height: 40),
                                  style: const ButtonStyle(
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap),
                                ),
                                Expanded(
                                    child: Tooltip(
                                  message: widget.title,
                                  child: fullscreen
                                      ? SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Text(widget.title,
                                              maxLines: 1,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16)))
                                      : const SizedBox.shrink(),
                                )),
                              ]),
                            ),
                          ),
                        ),
                        if (widget.failure == null)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: _gradient(),
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                              child: SafeArea(
                                  top: false,
                                  bottom: fullscreen,
                                  child: _bottomControls(fullscreen)),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                if (widget.failure != null)
                  Positioned.fill(child: widget.failure!),
                if ((widget.loading ||
                        widget.player.state.buffering &&
                            widget.player.state.playing) &&
                    widget.failure == null)
                  RecordingPlaybackLoading(
                    buffering: widget.player.state.buffering,
                    buffered: widget.player.state.buffer,
                    onRetry: widget.onReload,
                  ),
                if (_episodePanelVisible) ...[
                  Positioned.fill(
                      child: FadeTransition(
                    opacity: _episodeAnimation,
                    child: GestureDetector(
                      onTap: _episodesOpen ? _closeEpisodes : null,
                      child: const ColoredBox(color: Colors.black38),
                    ),
                  )),
                  Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: math.min(500, constraints.maxWidth * .5),
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(1, 0),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: _episodeAnimation,
                          curve: Curves.easeInOut,
                        )),
                        child: _episodePanel(),
                      )),
                ],
              ]),
            );
          }),
        ),
      ),
    );
  }

  Widget _floatingView(BoxConstraints constraints) {
    final width = math.min(200.0, constraints.maxWidth * .4);
    final height = width * 9 / 16;
    final maxLeft = math.max(8.0, constraints.maxWidth - width - 8);
    final maxTop = math.max(8.0, constraints.maxHeight - height - 90);
    final desired = _floatingPosition ?? Offset(maxLeft - 8, 64);
    final position =
        Offset(desired.dx.clamp(8.0, maxLeft), desired.dy.clamp(8.0, maxTop));
    return Positioned(
      key: const ValueKey('recording-secondary-view'),
      left: position.dx,
      top: position.dy,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: widget.loading ? null : widget.onSwapViews,
        onPanUpdate: (details) => setState(() {
          final current = _floatingPosition ?? position;
          _floatingPosition = Offset(
            (current.dx + details.delta.dx).clamp(8.0, maxLeft),
            (current.dy + details.delta.dy).clamp(8.0, maxTop),
          );
        }),
        child: Semantics(
          label: '${widget.secondaryLabel}副画面，点击交换，拖动移动',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)),
              child: widget.secondaryView!,
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodePanel() => Material(
        color: const Color(0xF51C1C1C),
        child: SafeArea(
            child: Column(children: [
          Row(children: [
            const SizedBox(width: 16),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('选集（${widget.lessons.length}）',
                    style: const TextStyle(color: Colors.white)),
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            )),
            IconButton(
                tooltip: '收起选集',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _closeEpisodes),
          ]),
          Expanded(
              child: Scrollbar(
                  child: ListView.builder(
            key: const ValueKey('fullscreen-episode-list'),
            itemCount: widget.lessons.length,
            itemBuilder: (context, index) {
              final lesson = widget.lessons[index];
              final selected = lesson.id == widget.selectedLessonId;
              final begin = lesson.beginTime;
              final date = begin == null
                  ? lesson.sectionLabel
                  : '${begin.month}月${begin.day}日 ${begin.hour.toString().padLeft(2, '0')}:${begin.minute.toString().padLeft(2, '0')}';
              return ListTile(
                key: ValueKey('fullscreen-lesson-${lesson.id}'),
                enabled: lesson.canPlay,
                selected: selected,
                selectedTileColor:
                    Theme.of(context).colorScheme.primary.withValues(alpha: .2),
                leading: RecordingStatusIcon(
                    isLive: lesson.isLive,
                    enabled: lesson.canPlay,
                    disabledColor: Colors.white38),
                title: Text('第 ${widget.lessons.length - index} 集 · $date',
                    style: TextStyle(
                        color: !lesson.canPlay
                            ? Colors.white38
                            : selected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white,
                        fontSize: 14)),
                subtitle: Text(
                    [
                      if (begin != null && lesson.sectionLabel.isNotEmpty)
                        lesson.sectionLabel,
                      lesson.statusLabel
                    ].join(' · '),
                    style: TextStyle(
                        color: lesson.canPlay ? Colors.white70 : Colors.white38,
                        fontSize: 12)),
                onTap: !lesson.canPlay
                    ? null
                    : () {
                        if (!selected) widget.onLessonSelected?.call(lesson);
                        _closeEpisodes();
                      },
              );
            },
          ))),
        ])),
      );

  BoxDecoration _gradient({bool top = false}) => BoxDecoration(
          gradient: LinearGradient(
        begin: top ? Alignment.topCenter : Alignment.bottomCenter,
        end: top ? Alignment.bottomCenter : Alignment.topCenter,
        colors: const [Color(0xC0000000), Colors.transparent],
      ));

  Widget _bottomControls(bool fullscreen) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds.toDouble();
    final position = (_dragPosition ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, math.max(1.0, duration));
    final buffered = state.buffer.inMilliseconds
        .toDouble()
        .clamp(position, math.max(1.0, duration));
    final currentTime = _durationText(Duration(milliseconds: position.round()));
    final totalTime = _durationText(state.duration);
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 340;
      final buttonWidth = fullscreen && constraints.maxWidth >= 600
          ? 42.0
          : narrow
              ? 30.0
              : 35.0;
      final time = SizedBox(
        width: narrow ? 64 : 76,
        child: Column(
          key: const ValueKey('recording-playback-time'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(currentTime,
                maxLines: 1,
                style:
                    TextStyle(color: Colors.white, fontSize: narrow ? 11 : 13)),
            Text(totalTime,
                maxLines: 1,
                style: TextStyle(
                    color: Colors.white70, fontSize: narrow ? 11 : 13)),
          ],
        ),
      );
      Widget iconButton({
        required String tooltip,
        required IconData icon,
        required VoidCallback? onPressed,
        bool? selected,
        IconData? selectedIcon,
        double size = 22,
      }) =>
          IconButton(
            tooltip: tooltip,
            isSelected: selected,
            onPressed: onPressed,
            icon: Icon(icon, size: size),
            selectedIcon: selectedIcon == null
                ? null
                : Icon(selectedIcon,
                    size: size, color: Theme.of(context).colorScheme.primary),
            padding: EdgeInsets.zero,
            constraints:
                BoxConstraints.tightFor(width: buttonWidth, height: 34),
            style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white38,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          );
      final older = _adjacentLesson(1);
      final newer = _adjacentLesson(-1);
      final controls = <Widget>[
        if (fullscreen &&
            widget.views.length > 1 &&
            widget.onDualChanged != null)
          iconButton(
            tooltip: widget.dualEnabled ? '关闭双视角' : '开启双视角',
            selected: widget.dualEnabled,
            onPressed: widget.loading
                ? null
                : () {
                    widget.onDualChanged!(!widget.dualEnabled);
                    _showControls();
                  },
            icon: Icons.picture_in_picture_alt_outlined,
            selectedIcon: Icons.picture_in_picture_alt_rounded,
          ),
        if (widget.lessons.isNotEmpty)
          iconButton(
            tooltip: '选集',
            icon: Icons.list,
            onPressed: _openEpisodes,
          ),
        if (fullscreen && widget.onAspectChanged != null)
          PopupMenuButton<String>(
            tooltip: '画面比例',
            color: Colors.black.withValues(alpha: .8),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            requestFocus: false,
            initialValue: widget.aspect,
            onOpened: () => _hideTimer?.cancel(),
            onCanceled: _showControls,
            onSelected: (value) {
              widget.onAspectChanged!(value);
              _showControls();
            },
            itemBuilder: (_) => [
              for (final value in ['自动', '16:9', '4:3', '填充', '裁剪'])
                CheckedPopupMenuItem(
                    value: value,
                    height: 35,
                    checked: widget.aspect == value,
                    child: Text(value,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)))
            ],
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text(widget.aspect,
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
          ),
        if (!widget.isLive)
          PopupMenuButton<double>(
            tooltip: '播放速度',
            color: Colors.black.withValues(alpha: .8),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            requestFocus: false,
            enabled: !widget.loading,
            initialValue: state.rate,
            onOpened: () => _hideTimer?.cancel(),
            onCanceled: _showControls,
            onSelected: (rate) {
              unawaited(widget.player.setRate(rate));
              _showControls();
            },
            itemBuilder: (_) => [
              for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                CheckedPopupMenuItem(
                    value: rate,
                    height: 35,
                    checked: state.rate == rate,
                    child: Text('${rate == 1 ? '正常 ' : ''}${rate}x',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13)))
            ],
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text('${state.rate}X',
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
          ),
        if (widget.isLive)
          iconButton(
              tooltip: '回到直播',
              onPressed: widget.loading ? null : widget.onReconnect,
              icon: Icons.refresh),
        iconButton(
            tooltip: fullscreen ? '退出全屏' : '全屏',
            onPressed: widget.loading
                ? null
                : () => unawaited(widget.state.toggleFullscreen()),
            icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            size: 24),
      ];
      return IconTheme(
          data: const IconThemeData(color: Colors.white, size: 22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!widget.isLive)
              SizedBox(
                  height: 24,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                        trackHeight: 3.5,
                        trackShape: const RoundedRectSliderTrackShape(),
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                            elevation: 0,
                            pressedElevation: 0),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12)),
                    child: Slider(
                      value: position.toDouble(),
                      secondaryTrackValue: buffered.toDouble(),
                      min: 0,
                      max: math.max(1.0, duration),
                      inactiveColor: const Color(0x33FFFFFF),
                      secondaryActiveColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: .4),
                      onChangeStart: _beginSeek,
                      onChanged:
                          duration <= 0 || widget.loading ? null : _previewSeek,
                      onChangeEnd: (value) => unawaited(_finishSeek(value)),
                    ),
                  )),
            const SizedBox(height: 4),
            Row(key: const ValueKey('recording-bottom-controls'), children: [
              iconButton(
                  tooltip: state.playing ? '暂停' : '播放',
                  onPressed: widget.loading ? null : _togglePlayback,
                  icon: state.playing ? Icons.pause : Icons.play_arrow,
                  size: 26),
              if (!widget.isLive) time,
              if (widget.lessons.isNotEmpty) ...[
                iconButton(
                    tooltip: '上一集',
                    onPressed: widget.loading || older == null
                        ? null
                        : () => widget.onLessonSelected?.call(older),
                    icon: Icons.skip_previous),
                iconButton(
                    tooltip: '下一集',
                    onPressed: widget.loading || newer == null
                        ? null
                        : () => widget.onLessonSelected?.call(newer),
                    icon: Icons.skip_next),
              ],
              if (widget.isLive)
                Text('● 直播',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12)),
              Expanded(
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: controls)))),
            ]),
          ]));
    });
  }
}

String _durationText(Duration duration) {
  final seconds = math.max(0, duration.inSeconds);
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:$minutes:$remainder'
      : '$minutes:$remainder';
}
