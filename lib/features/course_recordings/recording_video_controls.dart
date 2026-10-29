import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_episode_tile.dart';
import 'recording_episode_metadata.dart';
import 'recording_episode_sort_icon.dart';
import 'recording_playback_status.dart';
import 'recording_seek_controller.dart';

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
    this.liveProtocol = VodLiveProtocol.hls,
    this.onLiveProtocolChanged,
    this.onReconnect,
    this.lessons = const [],
    this.episodeLessons,
    this.episodeNewestFirst,
    this.onEpisodeOrderChanged,
    this.onClearClassroomFilter,
    this.selectedLessonId,
    this.selectedLesson,
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
    this.onTemporaryRate,
    this.primaryView,
    this.onReload,
    this.livePlaying,
    this.onLiveTogglePlayback,
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
  final VodLiveProtocol liveProtocol;
  final ValueChanged<VodLiveProtocol>? onLiveProtocolChanged;
  final VoidCallback? onReconnect;
  final List<VodLesson> lessons;
  final List<VodLesson>? episodeLessons;
  final bool? episodeNewestFirst;
  final ValueChanged<bool>? onEpisodeOrderChanged;
  final VoidCallback? onClearClassroomFilter;
  final int? selectedLessonId;
  final VodLesson? selectedLesson;
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
  final Future<void> Function(double rate)? onTemporaryRate;
  final Widget? primaryView;
  final VoidCallback? onReload;
  final bool? livePlaying;
  final VoidCallback? onLiveTogglePlayback;

  @override
  State<RecordingVideoControls> createState() => _RecordingVideoControlsState();
}

class _RecordingVideoControlsState extends State<RecordingVideoControls>
    with TickerProviderStateMixin {
  static const _episodeItemExtent = 80.0;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _episodeScrollController = ScrollController();
  late final AnimationController _episodeAnimation;
  late final AnimationController _controlsAnimation;
  late RecordingSeekController _seekController;
  Timer? _hideTimer;
  Timer? _doubleTapTimer;
  Timer? _seekPositionTimer;
  Offset? _lastTapPosition;
  bool _visible = true;
  bool _episodesOpen = false;
  bool _localNewestFirst = true;
  double? _dragPosition;
  Duration? _pendingSeekPosition;
  Offset? _floatingPosition;
  int _seekRevision = 0;
  Player? _longPressPlayer;
  double? _longPressPreviousRate;
  Future<void> _rateQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _controlsAnimation = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 100),
    );
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
    _subscriptions.add(widget.player.stream.position.listen((position) {
      if (!mounted) return;
      final pending = _pendingSeekPosition;
      if (pending != null && recordingSeekPositionMatches(position, pending)) {
        _clearPendingSeekPosition();
        setState(() => _dragPosition = null);
        _showControls();
      } else {
        setState(() {});
      }
    }));
    for (final stream in <Stream<dynamic>>[
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
      _endLongPress();
      _seekController.dispose();
      _seekRevision++;
      _clearPendingSeekPosition();
      _dragPosition = null;
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      _bindPlayer();
    } else if (oldWidget.selectedLessonId != widget.selectedLessonId ||
        oldWidget.isLive != widget.isLive ||
        !oldWidget.loading && widget.loading) {
      _endLongPress();
      _seekController.begin();
      _seekRevision++;
      _clearPendingSeekPosition();
      _dragPosition = null;
    }
  }

  @override
  void dispose() {
    _endLongPress(updateUi: false);
    if (_episodePanelVisible) {
      widget.onEpisodePanelVisibilityChanged?.call(false);
    }
    _hideTimer?.cancel();
    _seekController.dispose();
    _clearPendingSeekPosition();
    _doubleTapTimer?.cancel();
    _controlsAnimation.dispose();
    _episodeAnimation.dispose();
    _episodeScrollController.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  bool get _episodePanelVisible => _episodesOpen || _episodeAnimation.value > 0;

  bool get _playing => widget.livePlaying ?? widget.player.state.playing;

  void _startLongPress(LongPressStartDetails details) {
    if (widget.isLive ||
        widget.loading ||
        widget.failure != null ||
        _episodePanelVisible ||
        !widget.player.state.playing ||
        _longPressPlayer != null) {
      return;
    }
    final player = widget.player;
    setState(() {
      _longPressPlayer = player;
      _longPressPreviousRate = player.state.rate;
    });
    unawaited(HapticFeedback.lightImpact());
    _setTemporaryRate(player, 3);
  }

  void _endLongPress({bool updateUi = true}) {
    final player = _longPressPlayer;
    final previousRate = _longPressPreviousRate;
    if (player == null || previousRate == null) return;
    void clear() {
      _longPressPlayer = null;
      _longPressPreviousRate = null;
    }

    if (updateUi && mounted) {
      setState(clear);
    } else {
      clear();
    }
    _setTemporaryRate(player, previousRate);
  }

  void _setTemporaryRate(Player player, double rate) {
    final setRate = widget.onTemporaryRate;
    _rateQueue = _rateQueue.then((_) async {
      try {
        if (setRate == null) {
          await player.setRate(rate);
        } else {
          await setRate(rate);
        }
      } on Object catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'course recordings',
            context:
                ErrorDescription('while changing temporary playback speed')));
      }
    });
  }

  void _clearPendingSeekPosition() {
    _seekPositionTimer?.cancel();
    _seekPositionTimer = null;
    _pendingSeekPosition = null;
  }

  void _beginSeek(double value) {
    _seekRevision++;
    _clearPendingSeekPosition();
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
    final target = Duration(milliseconds: value.round());
    setState(() => _dragPosition = value);
    var failed = false;
    try {
      await _seekController.finish(target);
    } catch (error, stack) {
      failed = true;
      _reportSeekError(error, stack);
    } finally {
      if (mounted && revision == _seekRevision) {
        if (failed ||
            recordingSeekPositionMatches(
                widget.player.state.position, target)) {
          setState(() => _dragPosition = null);
        } else {
          _pendingSeekPosition = target;
          _seekPositionTimer = Timer(recordingSeekPositionTimeout, () {
            if (!mounted || revision != _seekRevision) return;
            _clearPendingSeekPosition();
            setState(() => _dragPosition = null);
            _showControls();
          });
        }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _episodesOpen) _jumpToCurrentEpisode(showMessage: false);
    });
  }

  void _closeEpisodes() {
    setState(() => _episodesOpen = false);
    unawaited(_episodeAnimation.reverse());
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _visible = true);
    unawaited(_controlsAnimation.forward());
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing && _dragPosition == null && !_episodesOpen) {
        _hideControls();
      }
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    setState(() => _visible = false);
    unawaited(_controlsAnimation.reverse());
  }

  void _handleSurfaceTap(TapUpDetails details) {
    final lastPosition = _lastTapPosition;
    if (_doubleTapTimer?.isActive == true &&
        lastPosition != null &&
        (details.localPosition - lastPosition).distance <= kDoubleTapSlop) {
      _doubleTapTimer?.cancel();
      _lastTapPosition = null;
      _togglePlayback();
      return;
    }
    _doubleTapTimer?.cancel();
    _lastTapPosition = details.localPosition;
    _doubleTapTimer = Timer(kDoubleTapTimeout, () => _lastTapPosition = null);
    _visible ? _hideControls() : _showControls();
  }

  Widget _controlBar({required bool top, required Widget child}) =>
      SlideTransition(
        key: ValueKey(top
            ? 'recording-top-controls-transition'
            : 'recording-bottom-controls-transition'),
        position:
            Tween<Offset>(begin: Offset(0, top ? -1 : 1.2), end: Offset.zero)
                .animate(_controlsAnimation),
        child: child,
      );

  void _togglePlayback() {
    if (widget.loading || widget.failure != null) return;
    if (widget.isLive && widget.onLiveTogglePlayback != null) {
      widget.onLiveTogglePlayback!();
    } else if (widget.isLive &&
        !widget.player.state.playing &&
        widget.onReconnect != null) {
      widget.onReconnect!();
    } else {
      unawaited(widget.player.playOrPause());
    }
    _showControls();
  }

  VodLesson? _adjacentLesson(int direction) {
    final allowed = widget.episodeLessons?.map((lesson) => lesson.id).toSet();
    final index = widget.lessons
        .indexWhere((lesson) => lesson.id == widget.selectedLessonId);
    if (index < 0) return null;
    for (var candidate = index + direction;
        candidate >= 0 && candidate < widget.lessons.length;
        candidate += direction) {
      if (widget.lessons[candidate].canPlay &&
          (allowed == null || allowed.contains(widget.lessons[candidate].id))) {
        return widget.lessons[candidate];
      }
    }
    return null;
  }

  bool get _newestFirst => widget.episodeNewestFirst ?? _localNewestFirst;

  List<VodLesson> get _panelLessons {
    final lessons = widget.episodeLessons ?? widget.lessons;
    return _newestFirst ? lessons : lessons.reversed.toList(growable: false);
  }

  void _jumpToEpisodePosition(double offset) {
    if (!_episodeScrollController.hasClients) return;
    final position = _episodeScrollController.position;
    position.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  void _jumpToLastEpisode() {
    if (_episodeScrollController.hasClients) {
      _jumpToEpisodePosition(_episodeScrollController.position.maxScrollExtent);
    }
  }

  void _jumpToCurrentEpisode({bool showMessage = true}) {
    final index = _panelLessons
        .indexWhere((lesson) => lesson.id == widget.selectedLessonId);
    if (index >= 0) {
      _jumpToEpisodePosition(index * _episodeItemExtent);
    } else if (showMessage && widget.selectedLessonId != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: const Text('当前课次不在教室筛选结果中'),
        action: widget.onClearClassroomFilter == null
            ? null
            : SnackBarAction(
                label: '清除筛选', onPressed: widget.onClearClassroomFilter!),
      ));
    }
  }

  void _reverseEpisodes() {
    final next = !_newestFirst;
    if (widget.onEpisodeOrderChanged != null) {
      widget.onEpisodeOrderChanged!(next);
    } else {
      setState(() => _localNewestFirst = next);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _episodesOpen) _jumpToCurrentEpisode(showMessage: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = widget.fullscreen;
    final selectedLesson = widget.selectedLesson ??
        widget.lessons
            .where((lesson) => lesson.id == widget.selectedLessonId)
            .firstOrNull;
    final episodeHeading = selectedLesson == null
        ? ''
        : recordingFullscreenEpisodeHeading(selectedLesson);
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
            final safeInsets = fullscreen
                ? MediaQuery.viewPaddingOf(context)
                : EdgeInsets.zero;
            return GestureDetector(
              key: const ValueKey('recording-control-surface'),
              behavior: HitTestBehavior.opaque,
              onTapUp: _handleSurfaceTap,
              onLongPressStart: _startLongPress,
              onLongPressEnd: (_) => _endLongPress(),
              onLongPressCancel: _endLongPress,
              child: Stack(children: [
                if (widget.primaryView != null)
                  Positioned.fill(
                      child: IgnorePointer(child: widget.primaryView!)),
                if (!widget.isLive)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: FractionalTranslation(
                        translation: Offset(0, fullscreen ? 1.2 : .8),
                        child: AnimatedOpacity(
                          key: const ValueKey('recording-long-press-speed'),
                          opacity: _longPressPlayer == null ? 0 : 1,
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeInOut,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0x88000000),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Text('3.0倍速中',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_visible || _episodePanelVisible,
                    child: ClipRect(
                      key: const ValueKey('recording-controls-overlay'),
                      child: Stack(children: [
                        Align(
                          alignment: Alignment.topCenter,
                          child: _controlBar(
                            top: true,
                            child: Container(
                              decoration: _gradient(top: true),
                              padding: EdgeInsets.symmetric(
                                  horizontal: fullscreen ? 10 : 4,
                                  vertical: fullscreen ? 10 : 4),
                              child: Padding(
                                padding: EdgeInsets.only(
                                    left: safeInsets.left,
                                    top: safeInsets.top,
                                    right: safeInsets.right),
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
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SingleChildScrollView(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  child: Text(widget.title,
                                                      key: const ValueKey(
                                                          'recording-fullscreen-title'),
                                                      maxLines: 1,
                                                      style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          fontSize: 16))),
                                              if (episodeHeading.isNotEmpty)
                                                Text(episodeHeading,
                                                    key: const ValueKey(
                                                        'recording-fullscreen-episode-heading'),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 12)),
                                            ],
                                          )
                                        : const SizedBox.shrink(),
                                  )),
                                ]),
                              ),
                            ),
                          ),
                        ),
                        if (widget.failure == null)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _controlBar(
                              top: false,
                              child: Container(
                                decoration: _gradient(),
                                padding:
                                    const EdgeInsets.fromLTRB(10, 8, 10, 12),
                                child: Padding(
                                    padding: EdgeInsets.only(
                                        left: safeInsets.left,
                                        right: safeInsets.right,
                                        bottom: safeInsets.bottom),
                                    child: _bottomControls(fullscreen)),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
                if (!widget.isLive && widget.failure == null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: fullscreen ? safeInsets.bottom : 0,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: FadeTransition(
                          key:
                              const ValueKey('recording-compact-progress-fade'),
                          opacity: ReverseAnimation(_controlsAnimation),
                          child: _compactProgressBar(),
                        ),
                      ),
                    ),
                  ),
                if (fullscreen &&
                    widget.dualEnabled &&
                    widget.views.length > 1 &&
                    widget.secondaryView != null)
                  _floatingView(constraints, safeInsets),
                if (widget.failure != null)
                  Positioned.fill(child: widget.failure!),
                if (widget.failure != null &&
                    widget.isLive &&
                    widget.onLiveProtocolChanged != null)
                  Positioned(
                    right: safeInsets.right + 16,
                    bottom: safeInsets.bottom + 12,
                    child: _liveProtocolMenu(),
                  ),
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
                      width: math.min(
                          constraints.maxWidth,
                          math.max(math.min(500, constraints.maxWidth * .5),
                              260 + safeInsets.right)),
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(1, 0),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: _episodeAnimation,
                          curve: Curves.easeInOut,
                        )),
                        child: _episodePanel(safeInsets),
                      )),
                ],
              ]),
            );
          }),
        ),
      ),
    );
  }

  Widget _floatingView(BoxConstraints constraints, EdgeInsets safeInsets) {
    final availableWidth =
        math.max(0.0, constraints.maxWidth - safeInsets.horizontal);
    final availableHeight =
        math.max(0.0, constraints.maxHeight - safeInsets.vertical);
    final margin =
        math.min(8.0, math.min(availableWidth / 2, availableHeight / 2));
    final width = math.min(
        200.0,
        math.min(
            constraints.maxWidth * .4,
            math.min(availableWidth - margin * 2,
                (availableHeight - margin * 2) * 16 / 9)));
    final height = width * 9 / 16;
    final minLeft = safeInsets.left + margin;
    final minTop = safeInsets.top + margin;
    final maxLeft = math.max(
        minLeft, constraints.maxWidth - safeInsets.right - width - margin);
    final maxTop = math.max(
        minTop, constraints.maxHeight - safeInsets.bottom - height - margin);
    final desired =
        _floatingPosition ?? Offset(maxLeft - 8, safeInsets.top + 64);
    final position = Offset(
        desired.dx.clamp(minLeft, maxLeft), desired.dy.clamp(minTop, maxTop));
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
            (current.dx + details.delta.dx).clamp(minLeft, maxLeft),
            (current.dy + details.delta.dy).clamp(minTop, maxTop),
          );
        }),
        child: Semantics(
          label: '${widget.secondaryLabel}副画面，点击交换，拖动移动',
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black54,
                    blurRadius: 12,
                    offset: Offset(0, 4)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2)),
                child: widget.secondaryView!,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodePanel(EdgeInsets safeInsets) {
    final panelLessons = _panelLessons;
    final colors = context.shuyoColors;
    return Material(
      key: const ValueKey('recording-fullscreen-episode-panel'),
      color: colors.surface,
      child: Padding(
          padding: EdgeInsets.only(
              top: safeInsets.top,
              right: safeInsets.right,
              bottom: safeInsets.bottom),
          child: Column(children: [
            _episodePanelToolbar(),
            Expanded(
                child: widget.episodeLessons != null &&
                        widget.episodeLessons!.isEmpty
                    ? Center(
                        child: Text('没有符合教室筛选的课次',
                            style: TextStyle(color: colors.textSecondary)))
                    : Scrollbar(
                        child: ListView.builder(
                        key: const ValueKey('fullscreen-episode-list'),
                        controller: _episodeScrollController,
                        itemExtent: _episodeItemExtent,
                        padding: EdgeInsets.zero,
                        itemCount: panelLessons.length,
                        itemBuilder: (context, index) {
                          final lesson = panelLessons[index];
                          final originalIndex = widget.lessons
                              .indexWhere((item) => item.id == lesson.id);
                          final selected = lesson.id == widget.selectedLessonId;
                          return RecordingEpisodeTile(
                            tileKey: ValueKey('fullscreen-lesson-${lesson.id}'),
                            lesson: lesson,
                            number: widget.lessons.length - originalIndex,
                            selected: selected,
                            onTap: !lesson.canPlay
                                ? null
                                : () {
                                    if (!selected) {
                                      widget.onLessonSelected?.call(lesson);
                                    }
                                    _closeEpisodes();
                                  },
                          );
                        },
                      ))),
          ])),
    );
  }

  Widget _episodePanelToolbar() => Container(
        height: 45,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.shuyoColors.border)),
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = ((constraints.maxWidth - 50) / 5).clamp(24.0, 36.0);
          Widget button(String tooltip, Widget icon, VoidCallback? onPressed) =>
              SizedBox(
                width: width,
                height: 36,
                child: IconButton(
                  tooltip: tooltip,
                  onPressed: onPressed,
                  icon: icon,
                  style: IconButton.styleFrom(
                    foregroundColor: context.shuyoColors.textPrimary,
                    disabledForegroundColor: context.shuyoColors.textMuted,
                    padding: EdgeInsets.zero,
                    iconSize: 22,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              );
          final hasLessons = _panelLessons.isNotEmpty;
          final hasCurrent = widget.lessons
              .any((lesson) => lesson.id == widget.selectedLessonId);
          return Row(children: [
            Text('剧集',
                style: TextStyle(
                    color: context.shuyoColors.textPrimary, fontSize: 16)),
            button('跳至顶部', const Icon(Icons.vertical_align_top),
                hasLessons ? () => _jumpToEpisodePosition(0) : null),
            button('跳至底部', const Icon(Icons.vertical_align_bottom),
                hasLessons ? _jumpToLastEpisode : null),
            button('跳至当前', const Icon(Icons.my_location),
                hasCurrent ? _jumpToCurrentEpisode : null),
            const Spacer(),
            button(
                _newestFirst ? '切换为正序' : '切换为倒序',
                RecordingEpisodeSortIcon(descending: _newestFirst),
                hasLessons ? _reverseEpisodes : null),
            button('收起选集', const Icon(Icons.close), _closeEpisodes),
          ]);
        }),
      );

  BoxDecoration _gradient({bool top = false}) => BoxDecoration(
          gradient: LinearGradient(
        begin: top ? Alignment.topCenter : Alignment.bottomCenter,
        end: top ? Alignment.bottomCenter : Alignment.topCenter,
        colors: const [Color(0xC0000000), Colors.transparent],
      ));

  ({double maximum, double played, double buffered}) _progressValues() {
    final state = widget.player.state;
    if (state.duration <= Duration.zero) {
      return (maximum: 1, played: 0, buffered: 0);
    }
    final maximum = math.max(1.0, state.duration.inMilliseconds.toDouble());
    final played = (_dragPosition ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, maximum);
    final buffered =
        state.buffer.inMilliseconds.toDouble().clamp(played, maximum);
    return (maximum: maximum, played: played, buffered: buffered);
  }

  Color _progressColor() {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.light
        ? colors.inversePrimary
        : colors.primary;
  }

  Widget _compactProgressBar() {
    final progress = _progressValues();
    final primary = _progressColor();
    return ClipRRect(
      key: const ValueKey('recording-compact-progress'),
      child: SizedBox(
        height: 3.5,
        child: Stack(fit: StackFit.expand, children: [
          const ColoredBox(
            key: ValueKey('recording-compact-unbuffered'),
            color: Color(0x33FFFFFF),
          ),
          FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: progress.buffered / progress.maximum,
            child: ColoredBox(
              key: const ValueKey('recording-compact-buffered'),
              color: primary.withValues(alpha: .4),
            ),
          ),
          FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: progress.played / progress.maximum,
            child: ColoredBox(
              key: const ValueKey('recording-compact-played'),
              color: primary,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _liveProtocolMenu() => PopupMenuButton<VodLiveProtocol>(
        tooltip: '直播线路',
        color: Colors.black.withValues(alpha: .8),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        enabled: !widget.loading,
        initialValue: widget.liveProtocol,
        onOpened: () => _hideTimer?.cancel(),
        onCanceled: _showControls,
        onSelected: (value) {
          widget.onLiveProtocolChanged!(value);
          _showControls();
        },
        itemBuilder: (_) => [
          for (final protocol in VodLiveProtocol.values)
            PopupMenuItem(
              value: protocol,
              height: 35,
              child: Text(
                protocol == VodLiveProtocol.webRtc
                    ? 'WebRTC'
                    : protocol.name.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            widget.liveProtocol == VodLiveProtocol.webRtc
                ? 'WebRTC'
                : widget.liveProtocol.name.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      );

  Widget _bottomControls(bool fullscreen) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds.toDouble();
    final progress = _progressValues();
    final position = progress.played;
    final buffered = progress.buffered;
    final progressColor = _progressColor();
    final currentTime = _durationText(Duration(milliseconds: position.round()));
    final totalTime = _durationText(state.duration);
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 340;
      final buttonWidth = fullscreen && constraints.maxWidth >= 600
          ? 42.0
          : narrow
              ? 30.0
              : 35.0;
      final time = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: narrow ? 64 : 76),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            key: const ValueKey('recording-playback-time'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(currentTime,
                  maxLines: 1,
                  style: TextStyle(
                      color: Colors.white, fontSize: narrow ? 11 : 13)),
              Text(totalTime,
                  maxLines: 1,
                  style: TextStyle(
                      color: Colors.white70, fontSize: narrow ? 11 : 13)),
            ],
          ),
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
        if (fullscreen && widget.lessons.isNotEmpty)
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
                PopupMenuItem(
                    value: value,
                    height: 35,
                    padding: const EdgeInsets.only(left: 30),
                    child: Semantics(
                      selected: widget.aspect == value,
                      child: Text(value,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ))
            ],
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
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
                PopupMenuItem(
                    value: rate,
                    height: 35,
                    padding: const EdgeInsets.only(left: 30),
                    child: Semantics(
                      selected: state.rate == rate,
                      child: Text('${rate}X',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ))
            ],
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('${state.rate}X',
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
          ),
        if (widget.isLive && widget.onLiveProtocolChanged != null)
          _liveProtocolMenu(),
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
                      max: progress.maximum,
                      activeColor: progressColor,
                      inactiveColor: const Color(0x33FFFFFF),
                      secondaryActiveColor: progressColor.withValues(alpha: .4),
                      onChangeStart: _beginSeek,
                      onChanged:
                          duration <= 0 || widget.loading ? null : _previewSeek,
                      onChangeEnd: (value) => unawaited(_finishSeek(value)),
                    ),
                  )),
            const SizedBox(height: 4),
            Row(key: const ValueKey('recording-bottom-controls'), children: [
              iconButton(
                  tooltip: _playing ? '暂停' : '播放',
                  onPressed: widget.loading ? null : _togglePlayback,
                  icon: _playing ? Icons.pause : Icons.play_arrow,
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
