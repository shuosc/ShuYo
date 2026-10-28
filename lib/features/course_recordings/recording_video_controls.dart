import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
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
    required this.onViewSelected,
    required this.softwareDecoding,
    this.onDecodingChanged,
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
  });

  final VideoState state;
  final Player player;
  final String title;
  final bool loading;
  final Widget? failure;
  final List<VodView> views;
  final int selectedView;
  final ValueChanged<int> onViewSelected;
  final bool softwareDecoding;
  final bool isLive;
  final VoidCallback? onReconnect;
  final VoidCallback? onDecodingChanged;
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

  @override
  State<RecordingVideoControls> createState() => _RecordingVideoControlsState();
}

class _RecordingVideoControlsState extends State<RecordingVideoControls>
    with SingleTickerProviderStateMixin {
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final AnimationController _episodeAnimation;
  Timer? _hideTimer;
  bool _visible = true;
  bool _episodesOpen = false;
  double? _dragPosition;
  Offset? _floatingPosition;

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
    for (final stream in <Stream<dynamic>>[
      widget.player.stream.position,
      widget.player.stream.duration,
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.rate,
    ]) {
      _subscriptions.add(stream.listen((_) {
        if (mounted) setState(() {});
      }));
    }
    _showControls();
  }

  @override
  void dispose() {
    if (_episodePanelVisible) {
      widget.onEpisodePanelVisibilityChanged?.call(false);
    }
    _hideTimer?.cancel();
    _episodeAnimation.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  bool get _episodePanelVisible => _episodesOpen || _episodeAnimation.value > 0;

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
    final fullscreen = widget.state.isFullscreen();
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
                if (widget.failure != null)
                  Positioned.fill(child: widget.failure!),
                if ((widget.loading || widget.player.state.buffering) &&
                    widget.failure == null)
                  const Center(
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 3)),
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
                                      color: Colors.white),
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
                                      : Text(widget.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16)),
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
                              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
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
    final currentTime = _durationText(Duration(milliseconds: position.round()));
    final totalTime = _durationText(state.duration);
    final time = Text('$currentTime / $totalTime',
        maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 12));
    final fullscreenTime = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(currentTime,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        Text(totalTime,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final older = _adjacentLesson(1);
      final newer = _adjacentLesson(-1);
      final controls = <Widget>[
        if (fullscreen &&
            widget.views.length > 1 &&
            widget.onDualChanged != null)
          IconButton(
            tooltip: widget.dualEnabled ? '关闭双视角' : '开启双视角',
            isSelected: widget.dualEnabled,
            onPressed: widget.loading
                ? null
                : () {
                    widget.onDualChanged!(!widget.dualEnabled);
                    _showControls();
                  },
            icon: const Icon(Icons.picture_in_picture_alt_outlined),
            selectedIcon: Icon(Icons.picture_in_picture_alt_rounded,
                color: Theme.of(context).colorScheme.primary),
          ),
        if (fullscreen && widget.lessons.isNotEmpty)
          TextButton(
              onPressed: _openEpisodes,
              child: const Text('选集', style: TextStyle(color: Colors.white))),
        if (fullscreen && widget.onAspectChanged != null)
          PopupMenuButton<String>(
            tooltip: '画面比例',
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
                    checked: widget.aspect == value,
                    child: Text(value))
            ],
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(widget.aspect,
                    style: const TextStyle(color: Colors.white, fontSize: 12))),
          ),
        if (!widget.isLive)
          PopupMenuButton<double>(
            tooltip: '播放速度',
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
                    checked: state.rate == rate,
                    child: Text('${rate == 1 ? '正常 ' : ''}${rate}x'))
            ],
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('${state.rate}x',
                    style: const TextStyle(color: Colors.white, fontSize: 12))),
          ),
        if (widget.isLive)
          IconButton(
              tooltip: '回到直播',
              onPressed: widget.loading ? null : widget.onReconnect,
              icon: const Icon(Icons.refresh)),
        if (widget.views.length > 1 || widget.onDecodingChanged != null)
          PopupMenuButton<int>(
            tooltip: '播放设置',
            enabled: !widget.loading,
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onOpened: () => _hideTimer?.cancel(),
            onCanceled: _showControls,
            onSelected: (value) {
              if (value == -1) {
                widget.onDecodingChanged?.call();
              } else {
                widget.onViewSelected(value);
              }
              _showControls();
            },
            itemBuilder: (_) => [
              for (var index = 0; index < widget.views.length; index++)
                CheckedPopupMenuItem(
                    value: index,
                    checked: index == widget.selectedView,
                    child: Text(widget.views[index].label)),
              if (widget.onDecodingChanged != null) ...[
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                    value: -1,
                    checked: widget.softwareDecoding,
                    child: const Text('使用软件解码')),
              ],
            ],
          ),
        IconButton(
            tooltip: fullscreen ? '退出全屏' : '全屏',
            onPressed: widget.loading
                ? null
                : () => unawaited(widget.state.toggleFullscreen()),
            icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen)),
      ];
      return IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!widget.isLive)
              SizedBox(
                  height: 24,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12)),
                    child: Slider(
                      value: position.toDouble(),
                      min: 0,
                      max: math.max(1.0, duration),
                      inactiveColor: Colors.white38,
                      onChanged: duration <= 0 || widget.loading
                          ? null
                          : (value) {
                              _hideTimer?.cancel();
                              setState(() => _dragPosition = value);
                            },
                      onChangeEnd: (value) {
                        unawaited(widget.player
                            .seek(Duration(milliseconds: value.round())));
                        setState(() => _dragPosition = null);
                        _showControls();
                      },
                    ),
                  )),
            if (compact && !fullscreen && !widget.isLive)
              Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                      padding: const EdgeInsets.only(left: 12), child: time)),
            Row(children: [
              IconButton(
                  tooltip: state.playing ? '暂停' : '播放',
                  onPressed: widget.loading ? null : _togglePlayback,
                  icon: Icon(state.playing ? Icons.pause : Icons.play_arrow)),
              if (fullscreen && !widget.isLive) fullscreenTime,
              if (!fullscreen && !compact && !widget.isLive) time,
              if (fullscreen && widget.lessons.isNotEmpty) ...[
                IconButton(
                    tooltip: '上一集',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.loading || older == null
                        ? null
                        : () => widget.onLessonSelected?.call(older),
                    icon: const Icon(Icons.skip_previous)),
                IconButton(
                    tooltip: '下一集',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.loading || newer == null
                        ? null
                        : () => widget.onLessonSelected?.call(newer),
                    icon: const Icon(Icons.skip_next)),
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
