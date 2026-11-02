import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_episode_tile.dart';
import 'recording_episode_metadata.dart';
import 'recording_episode_navigation.dart';
import 'recording_episode_sort_icon.dart';
import 'recording_fullscreen_status.dart';
import 'recording_lesson_selection.dart';
import 'recording_playback_info.dart';
import 'recording_player_menu.dart';
import 'recording_player_preferences.dart';
import 'recording_playback_status.dart';
import 'recording_seek_controller.dart';
import 'recording_secondary_video.dart';

typedef _ProgressPresentation = ({
  double maximum,
  double played,
  double buffered
});
typedef _TimePresentation = ({int playedSeconds, int totalSeconds});
typedef _LoadingPresentation = ({
  bool playing,
  bool buffering,
  int bufferedSeconds
});

class RecordingVideoControls extends StatefulWidget {
  const RecordingVideoControls({
    super.key,
    required this.state,
    required this.player,
    this.timelinePlayer,
    required this.title,
    this.termLabel,
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
    this.viewControllers = const [],
    this.primaryController,
    this.onReload,
    this.preferences = const RecordingPlayerPreferences(),
    this.onPreferencesChanged,
    this.informationLoader,
    this.livePlaying,
    this.onLiveTogglePlayback,
    this.liveResolutionLabel,
  });

  final VideoState state;
  final Player player;
  final Player? timelinePlayer;
  final String title;
  final String? termLabel;
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
  final List<VideoController> viewControllers;
  final VideoController? primaryController;
  final VoidCallback? onReload;
  final RecordingPlayerPreferences preferences;
  final ValueChanged<RecordingPlayerPreferences>? onPreferencesChanged;
  final Future<List<RecordingPlaybackInfoEntry>> Function()? informationLoader;
  final bool? livePlaying;
  final VoidCallback? onLiveTogglePlayback;
  final Widget? liveResolutionLabel;

  @override
  State<RecordingVideoControls> createState() => _RecordingVideoControlsState();
}

class _RecordingVideoControlsState extends State<RecordingVideoControls>
    with TickerProviderStateMixin {
  Player get _clockPlayer => widget.timelinePlayer ?? widget.player;
  static const _episodeItemExtent = 80.0;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _loadingSubscriptions = <StreamSubscription<dynamic>>[];
  // PiliPlus 265f879fa85973b4bf885bde2562f1007f1013b8 keeps displayed
  // seconds separate from raw position listeners. Keep seek/slider precision,
  // while publishing only changes to each independent UI projection.
  final _progressPresentation = ValueNotifier<_ProgressPresentation>(
      (maximum: 1, played: 0, buffered: 0));
  final _timePresentation =
      ValueNotifier<_TimePresentation>((playedSeconds: 0, totalSeconds: 0));
  final _loadingPresentation = ValueNotifier<_LoadingPresentation>(
      (playing: false, buffering: false, bufferedSeconds: 0));
  final _playingPresentation = ValueNotifier(false);
  final _ratePresentation = ValueNotifier(1.0);
  final _episodeNavigationCache = RecordingEpisodeNavigationCache();
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
  bool _menuOpen = false;
  bool _localNewestFirst = true;
  double? _dragPosition;
  Offset? _surfaceDragOrigin;
  ({double position, double dx, double duration, double width})? _surfaceSeek;
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
    _bindLoadingPlayer();
    _showControls();
  }

  void _bindPlayer() {
    _seekController = RecordingSeekController(
      seek: (position) =>
          widget.onSeek?.call(position) ?? _clockPlayer.seek(position),
      onPreviewError: _reportSeekError,
    );
    _subscriptions.add(_clockPlayer.stream.position.listen((position) {
      if (!mounted) return;
      final pending = _pendingSeekPosition;
      if (pending != null && recordingSeekPositionMatches(position, pending)) {
        _clearPendingSeekPosition();
        _dragPosition = null;
        _timelineChanged();
        _showControls();
      } else {
        _timelineChanged();
      }
    }));
    for (final stream in <Stream<dynamic>>[
      _clockPlayer.stream.duration,
      _clockPlayer.stream.buffer,
    ]) {
      _subscriptions.add(stream.listen((_) => _timelineChanged()));
    }
    _subscriptions.add(_clockPlayer.stream.playing.listen((_) {
      if (mounted) _playingPresentation.value = _playing;
    }));
    _subscriptions.add(_clockPlayer.stream.rate.listen((rate) {
      if (mounted) _ratePresentation.value = rate;
    }));
    _timelineChanged();
    _playingPresentation.value = _playing;
    _ratePresentation.value = _clockPlayer.state.rate;
  }

  void _bindLoadingPlayer() {
    for (final subscription in _loadingSubscriptions) {
      unawaited(subscription.cancel());
    }
    _loadingSubscriptions.clear();
    // The loading overlay describes the visible decoder, which can differ from
    // the timeline decoder after a persistent dual-view role exchange.
    for (final stream in <Stream<dynamic>>[
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.buffer,
    ]) {
      _loadingSubscriptions.add(stream.listen((_) => _loadingChanged()));
    }
    _loadingChanged();
  }

  void _loadingChanged() {
    if (!mounted) return;
    final state = widget.player.state;
    _loadingPresentation.value = (
      playing: state.playing,
      buffering: state.buffering,
      bufferedSeconds: state.buffering ? state.buffer.inSeconds : 0,
    );
  }

  bool _showLiveLoadingMask(_LoadingPresentation loading) =>
      widget.isLive &&
      widget.failure == null &&
      (widget.loading || loading.buffering);

  @override
  void didUpdateWidget(covariant RecordingVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.timelinePlayer ?? oldWidget.player) != _clockPlayer) {
      _endLongPress();
      _seekController.dispose();
      _seekRevision++;
      _clearPendingSeekPosition();
      _dragPosition = null;
      _surfaceSeek = null;
      _surfaceDragOrigin = null;
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
      _surfaceSeek = null;
      _surfaceDragOrigin = null;
    }
    if (oldWidget.player != widget.player) _bindLoadingPlayer();
    _timelineChanged();
    _playingPresentation.value = _playing;
    _ratePresentation.value = _clockPlayer.state.rate;
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
    _progressPresentation.dispose();
    _timePresentation.dispose();
    _loadingPresentation.dispose();
    _playingPresentation.dispose();
    _ratePresentation.dispose();
    for (final subscription in [..._subscriptions, ..._loadingSubscriptions]) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  bool get _episodePanelVisible => _episodesOpen || _episodeAnimation.value > 0;

  bool get _playing => widget.livePlaying ?? _clockPlayer.state.playing;

  void _timelineChanged() {
    if (!mounted) return;
    final progress = _progressValues();
    _progressPresentation.value = progress;
    _timePresentation.value = (
      playedSeconds: Duration(milliseconds: progress.played.round()).inSeconds,
      totalSeconds: math.max(0, _clockPlayer.state.duration.inSeconds),
    );
  }

  Widget _progressView(
          Widget Function(BuildContext, _ProgressPresentation) builder) =>
      ValueListenableBuilder<_ProgressPresentation>(
        valueListenable: _progressPresentation,
        builder: (context, progress, _) => builder(context, progress),
      );

  void _startLongPress(LongPressStartDetails details) {
    if (widget.isLive ||
        widget.loading ||
        widget.failure != null ||
        _episodePanelVisible ||
        !_clockPlayer.state.playing ||
        _longPressPlayer != null) {
      return;
    }
    final player = _clockPlayer;
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

  bool get _canSurfaceSeek =>
      !widget.isLive &&
      !widget.loading &&
      widget.failure == null &&
      !_episodePanelVisible &&
      !_menuOpen &&
      _clockPlayer.state.duration > Duration.zero;

  void _startSurfaceSeek(DragStartDetails details, double width) {
    if (!_canSurfaceSeek || width <= 0) return;
    final origin = _surfaceDragOrigin;
    if (origin == null) return;
    final delta = details.localPosition - origin;
    // A horizontal recognizer may win by default when a long press rejects
    // vertical movement. Only start seeking after actual horizontal movement.
    if (delta.dx.abs() <= delta.dy.abs()) return;
    final duration = _clockPlayer.state.duration.inMilliseconds.toDouble();
    final position =
        (_dragPosition ?? _clockPlayer.state.position.inMilliseconds.toDouble())
            .clamp(0.0, duration);
    _surfaceSeek = (
      position: position,
      dx: origin.dx,
      duration: duration,
      width: width,
    );
    _doubleTapTimer?.cancel();
    _lastTapPosition = null;
    _showControls();
    _beginSeek(position);
    _previewSeek((position + delta.dx / width * duration).clamp(0.0, duration));
  }

  void _updateSurfaceSeek(DragUpdateDetails details) {
    final start = _surfaceSeek;
    if (start == null) return;
    final value = (start.position +
            (details.localPosition.dx - start.dx) /
                start.width *
                start.duration)
        .clamp(0.0, start.duration);
    _previewSeek(value);
  }

  void _finishSurfaceSeek() {
    _surfaceDragOrigin = null;
    if (_surfaceSeek == null) return;
    _surfaceSeek = null;
    // Previews already seek the player, so cancellation commits the latest
    // target too, just as releasing the progress slider does.
    unawaited(_finishSeek(_dragPosition!));
  }

  void _beginSeek(double value) {
    _seekRevision++;
    _clearPendingSeekPosition();
    _seekController.begin();
    _hideTimer?.cancel();
    _dragPosition = value;
    _timelineChanged();
  }

  void _previewSeek(double value) {
    _hideTimer?.cancel();
    _dragPosition = value;
    _timelineChanged();
    _seekController.preview(Duration(milliseconds: value.round()));
  }

  Future<void> _finishSeek(double value) async {
    final revision = ++_seekRevision;
    final target = Duration(milliseconds: value.round());
    _dragPosition = value;
    _timelineChanged();
    var failed = false;
    try {
      await _seekController.finish(target);
    } catch (error, stack) {
      failed = true;
      _reportSeekError(error, stack);
    } finally {
      if (mounted && revision == _seekRevision) {
        if (failed ||
            recordingSeekPositionMatches(_clockPlayer.state.position, target)) {
          _dragPosition = null;
          _timelineChanged();
        } else {
          _pendingSeekPosition = target;
          _seekPositionTimer = Timer(recordingSeekPositionTimeout, () {
            if (!mounted || revision != _seekRevision) return;
            _clearPendingSeekPosition();
            _dragPosition = null;
            _timelineChanged();
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

  Future<void> _openMore() async {
    if (_menuOpen) return;
    _hideTimer?.cancel();
    setState(() => _menuOpen = true);
    try {
      await showRecordingPlayerMenu(
        context: context,
        fullscreen: widget.fullscreen,
        preferences:
            widget.preferences.copyWith(secondaryView: widget.dualEnabled),
        onPreferencesChanged: widget.onPreferencesChanged,
        secondaryAvailable:
            widget.views.length > 1 && widget.onDualChanged != null,
        views: widget.views,
        informationLoader: widget.informationLoader ??
            () => readRecordingPlaybackInfo(widget.player,
                view: widget.views.elementAtOrNull(widget.selectedView)),
      );
    } finally {
      if (mounted) {
        setState(() => _menuOpen = false);
        _showControls();
      }
    }
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _visible = true);
    unawaited(_controlsAnimation.forward());
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          _playing &&
          _dragPosition == null &&
          !_episodesOpen &&
          !_menuOpen) {
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
        // Match PiliPlus's control-overlay paint isolation without changing
        // texture ownership or the existing slide transition.
        child: RepaintBoundary(child: child),
      );

  void _togglePlayback() {
    if (widget.loading || widget.failure != null) return;
    if (widget.isLive && widget.onLiveTogglePlayback != null) {
      widget.onLiveTogglePlayback!();
    } else if (widget.isLive &&
        !_clockPlayer.state.playing &&
        widget.onReconnect != null) {
      widget.onReconnect!();
    } else {
      unawaited(_clockPlayer.playOrPause());
    }
    _showControls();
  }

  RecordingEpisodeNavigation get _episodeNavigation =>
      _episodeNavigationCache.resolve(
        lessons: widget.lessons,
        episodeLessons: widget.episodeLessons,
        selectedLessonId: widget.selectedLessonId,
        newestFirst: _newestFirst,
      );

  VodLesson? _adjacentLesson(int direction) =>
      direction > 0 ? _episodeNavigation.older : _episodeNavigation.newer;

  bool get _newestFirst => widget.episodeNewestFirst ?? _localNewestFirst;

  List<VodLesson> get _panelLessons => _episodeNavigation.panelLessons;

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
    final index =
        _episodeNavigation.panelIndexByLessonId[widget.selectedLessonId];
    if (index != null) {
      _jumpToEpisodePosition(index * _episodeItemExtent);
    } else if (showMessage && widget.onClearClassroomFilter != null) {
      widget.onClearClassroomFilter!();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToCurrentEpisode(showMessage: false);
      });
    } else if (showMessage && widget.selectedLessonId != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: const Text('当前课次不在教室筛选结果中'),
        action: widget.onClearClassroomFilter == null
            ? null
            : SnackBarAction(
                label: '切换至当前教室', onPressed: widget.onClearClassroomFilter!),
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
    final selectedLesson =
        widget.selectedLesson ?? _episodeNavigation.selectedLesson;
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
            final floating = _floatingView(constraints, safeInsets);
            final showFloating = fullscreen &&
                widget.dualEnabled &&
                widget.views.length > 1 &&
                widget.secondaryView != null;
            final surfaces =
                _videoSurfaces(constraints, floating, showFloating);
            return GestureDetector(
              key: const ValueKey('recording-control-surface'),
              behavior: HitTestBehavior.opaque,
              onTapUp: _handleSurfaceTap,
              onLongPressStart: _startLongPress,
              onLongPressEnd: (_) => _endLongPress(),
              onLongPressCancel: _endLongPress,
              child: Stack(children: [
                if (surfaces.isNotEmpty)
                  surfaces.first
                else if (widget.primaryView != null)
                  Positioned.fill(
                      child: IgnorePointer(child: widget.primaryView!)),
                Positioned.fill(
                  child: ValueListenableBuilder<_LoadingPresentation>(
                    valueListenable: _loadingPresentation,
                    builder: (context, loading, _) =>
                        _showLiveLoadingMask(loading)
                            ? const IgnorePointer(
                                child: ColoredBox(
                                  key: ValueKey('recording-live-loading-mask'),
                                  color: Colors.black,
                                ),
                              )
                            : const SizedBox.shrink(),
                  ),
                ),
                // Keep seek gestures below buttons, the slider and the
                // floating view so those retain their own drag behavior.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragDown: _canSurfaceSeek
                        ? (details) =>
                            _surfaceDragOrigin = details.localPosition
                        : null,
                    onHorizontalDragStart: _canSurfaceSeek
                        ? (details) =>
                            _startSurfaceSeek(details, constraints.maxWidth)
                        : null,
                    onHorizontalDragUpdate:
                        _canSurfaceSeek ? _updateSurfaceSeek : null,
                    onHorizontalDragEnd:
                        _canSurfaceSeek ? (_) => _finishSurfaceSeek() : null,
                    onHorizontalDragCancel:
                        _canSurfaceSeek ? _finishSurfaceSeek : null,
                  ),
                ),
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 12),
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
                                        width: 42, height: 34),
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
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .baseline,
                                                    textBaseline:
                                                        TextBaseline.alphabetic,
                                                    children: [
                                                      Text(widget.title,
                                                          key: const ValueKey(
                                                              'recording-fullscreen-title'),
                                                          maxLines: 1,
                                                          style:
                                                              const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  fontSize:
                                                                      16)),
                                                      if (widget.termLabel
                                                              ?.isNotEmpty ??
                                                          false) ...[
                                                        const SizedBox(
                                                            width: 12),
                                                        Text(widget.termLabel!,
                                                            key: const ValueKey(
                                                                'recording-fullscreen-term'),
                                                            maxLines: 1,
                                                            style:
                                                                const TextStyle(
                                                                    color: Colors
                                                                        .white,
                                                                    fontSize:
                                                                        12)),
                                                      ],
                                                    ],
                                                  )),
                                              if (episodeHeading.isNotEmpty)
                                                Text(episodeHeading,
                                                    key: const ValueKey(
                                                        'recording-fullscreen-episode-heading'),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12)),
                                            ],
                                          )
                                        : const SizedBox.shrink(),
                                  )),
                                  if (fullscreen)
                                    RecordingFullscreenStatus(
                                      showClock: widget.preferences.showClock,
                                      active: _visible && !_episodePanelVisible,
                                    ),
                                  SizedBox(
                                    width: 42,
                                    height: 34,
                                    child: IconButton(
                                      key: const ValueKey(
                                          'recording-player-more'),
                                      tooltip: '更多设置',
                                      onPressed: _openMore,
                                      padding: EdgeInsets.zero,
                                      style: IconButton.styleFrom(
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap),
                                      icon: const Icon(Icons.more_vert_outlined,
                                          size: 19, color: Colors.white),
                                    ),
                                  ),
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
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 12),
                                child: Padding(
                                    padding: EdgeInsets.only(
                                        left: safeInsets.left,
                                        right: safeInsets.right),
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
                    bottom: 0,
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
                // Keep the floating texture above the control gradients. Its
                // keyed element stays in this Stack when the view roles swap.
                ...surfaces.skip(1),
                if (showFloating) floating,
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
                // All live-video children can be positioned. An inactive
                // non-positioned loading builder would otherwise make Stack
                // adopt its zero size and place controls outside the viewport.
                Positioned.fill(
                  child: ValueListenableBuilder<_LoadingPresentation>(
                    valueListenable: _loadingPresentation,
                    builder: (context, loading, _) => (widget.loading ||
                                loading.buffering &&
                                    (widget.isLive || loading.playing)) &&
                            widget.failure == null
                        ? RecordingPlaybackLoading(
                            buffering: loading.buffering,
                            buffered:
                                Duration(seconds: loading.bufferedSeconds),
                            onRetry: widget.onReload,
                          )
                        : const SizedBox.shrink(),
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

  List<Widget> _videoSurfaces(
      BoxConstraints constraints, Positioned floating, bool showFloating) {
    final controllers = [
      ...widget.viewControllers.where(
          (controller) => identical(controller, widget.primaryController)),
      ...widget.viewControllers.where(
          (controller) => !identical(controller, widget.primaryController)),
    ];
    return [
      for (final controller in controllers)
        Positioned(
          key: ObjectKey(controller),
          left: identical(controller, widget.primaryController)
              ? 0
              : floating.left,
          top: identical(controller, widget.primaryController)
              ? 0
              : floating.top,
          width: identical(controller, widget.primaryController)
              ? constraints.maxWidth
              : floating.width,
          height: identical(controller, widget.primaryController)
              ? constraints.maxHeight
              : floating.height,
          child: IgnorePointer(
            child: Opacity(
              opacity: identical(controller, widget.primaryController) ||
                      showFloating
                  ? 1
                  : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                      identical(controller, widget.primaryController) ? 0 : 8),
                  boxShadow: identical(controller, widget.primaryController)
                      ? null
                      : _floatingShadows,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                      identical(controller, widget.primaryController) ? 0 : 8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The host Video already paints this texture beneath
                      // the controls when it is the primary view.
                      if (identical(controller, widget.viewControllers.first) &&
                          identical(controller, widget.primaryController))
                        const SizedBox.expand()
                      else
                        RecordingSecondaryVideo(
                          controller: controller,
                          aspectRatio:
                              identical(controller, widget.primaryController)
                                  ? switch (widget.aspect) {
                                      '4:3' => 4 / 3,
                                      '16:9' => 16 / 9,
                                      _ => null,
                                    }
                                  : null,
                          fit: identical(controller, widget.primaryController)
                              ? switch (widget.aspect) {
                                  '填充' => BoxFit.fill,
                                  '裁剪' => BoxFit.cover,
                                  _ => BoxFit.contain,
                                }
                              : BoxFit.contain,
                        ),
                      if (!identical(controller, widget.primaryController))
                        ValueListenableBuilder<_LoadingPresentation>(
                          valueListenable: _loadingPresentation,
                          builder: (context, loading, _) =>
                              _showLiveLoadingMask(loading)
                                  ? const ColoredBox(color: Colors.black)
                                  : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  static const _floatingShadows = [
    BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
  ];

  Positioned _floatingView(BoxConstraints constraints, EdgeInsets safeInsets) {
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
              // Persistent textures are painted separately underneath this
              // transparent interaction frame, so their shadow belongs behind
              // the texture rather than on top of it.
              boxShadow:
                  widget.viewControllers.isEmpty ? _floatingShadows : null,
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
                child: widget.secondaryView,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodePanel(EdgeInsets safeInsets) {
    final panelLessons = _panelLessons;
    final numbers = _episodeNavigation.episodeNumbers;
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
                          final selected = lesson.id == widget.selectedLessonId;
                          return Column(children: [
                            Expanded(
                                child: RecordingEpisodeTile(
                              tileKey:
                                  ValueKey('fullscreen-lesson-${lesson.id}'),
                              lesson: lesson,
                              number: numbers[lesson.id]!,
                              selected: selected,
                              onTap: !recordingLessonCanSelect(lesson)
                                  ? null
                                  : () {
                                      if (!selected) {
                                        widget.onLessonSelected?.call(lesson);
                                      }
                                      _closeEpisodes();
                                    },
                            )),
                            if (index < panelLessons.length - 1)
                              const Divider(indent: 16, endIndent: 16),
                          ]);
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
          final hasCurrent = _episodeNavigation.hasCurrent;
          return Row(children: [
            Text('选集',
                style: ShuYoTextStyles.sectionTitle(
                    color: context.shuyoColors.textPrimary)),
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

  _ProgressPresentation _progressValues() {
    final state = _clockPlayer.state;
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

  Widget _compactProgressBar() => _progressView((context, progress) {
        final primary = _progressColor();
        return RepaintBoundary(
            child: ClipRRect(
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
        ));
      });

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
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 340;
      final buttonWidth = fullscreen && constraints.maxWidth >= 600
          ? 42.0
          : narrow
              ? 30.0
              : 35.0;
      final timeFontSize = fullscreen ? 14.0 : 13.0;
      final time = ValueListenableBuilder<_TimePresentation>(
          valueListenable: _timePresentation,
          builder: (context, time, _) {
            final currentTime =
                _durationText(Duration(seconds: time.playedSeconds));
            final totalTime =
                _durationText(Duration(seconds: time.totalSeconds));
            return ValueListenableBuilder<double>(
              valueListenable: _ratePresentation,
              builder: (context, rate, child) {
                final speedWidth = widget.isLive
                    ? 0.0
                    : TextPainter.computeWidth(
                            text: TextSpan(
                                text: '${rate}X',
                                style: DefaultTextStyle.of(context)
                                    .style
                                    .copyWith(fontSize: 13)),
                            textDirection: Directionality.of(context),
                            textScaler: MediaQuery.textScalerOf(context)) +
                        16;
                return ConstrainedBox(
                  key: const ValueKey('recording-playback-time'),
                  constraints: BoxConstraints(
                      maxWidth: math.min(
                          narrow ? 120 : 168,
                          math.max(
                              0,
                              constraints.maxWidth -
                                  42 -
                                  (widget.lessons.isEmpty
                                      ? 0
                                      : buttonWidth * 2) -
                                  buttonWidth -
                                  speedWidth))),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: child,
                  ),
                );
              },
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: currentTime),
                  TextSpan(
                      text: '/$totalTime',
                      style: const TextStyle(color: Color(0xFFD0D0D0))),
                ]),
                maxLines: 1,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: timeFontSize,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                    fontFamily: 'Monospace',
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            );
          });
      Widget iconButton({
        required String tooltip,
        required IconData icon,
        required VoidCallback? onPressed,
        bool? selected,
        IconData? selectedIcon,
        double size = 22,
        double height = 30,
        double? width,
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
            constraints: BoxConstraints.tightFor(
                width: width ?? buttonWidth, height: height),
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
          ValueListenableBuilder<double>(
            valueListenable: _ratePresentation,
            builder: (context, currentRate, _) => PopupMenuButton<double>(
              tooltip: '播放速度',
              color: Colors.black.withValues(alpha: .8),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              requestFocus: false,
              enabled: !widget.loading,
              initialValue: currentRate,
              onOpened: () => _hideTimer?.cancel(),
              onCanceled: _showControls,
              onSelected: (rate) {
                unawaited(_clockPlayer.setRate(rate));
                _showControls();
              },
              itemBuilder: (_) => [
                for (final rate in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                  PopupMenuItem(
                      value: rate,
                      height: 35,
                      padding: const EdgeInsets.only(left: 30),
                      child: Semantics(
                        selected: currentRate == rate,
                        child: Text('${rate}X',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ))
              ],
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('${currentRate}X',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13))),
            ),
          ),
        if (widget.isLive && widget.onLiveProtocolChanged != null)
          _liveProtocolMenu(),
        if (fullscreen && !widget.loading && widget.failure == null)
          if (widget.isLive && widget.liveProtocol == VodLiveProtocol.webRtc)
            widget.liveResolutionLabel ?? const SizedBox.shrink()
          else
            _RecordingPlayerResolutionLabel(player: widget.player),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
                child: _progressView((context, progress) {
                  final progressColor = _progressColor();
                  return RepaintBoundary(
                      child: SizedBox(
                          key: const ValueKey('recording-seek-track'),
                          height: 14,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.5,
                                trackShape: const RoundedRectSliderTrackShape(),
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 7,
                                    elevation: 0,
                                    pressedElevation: 0),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 12)),
                            child: Slider(
                              padding: EdgeInsets.zero,
                              value: progress.played,
                              secondaryTrackValue: progress.buffered,
                              min: 0,
                              max: progress.maximum,
                              activeColor: progressColor,
                              inactiveColor: const Color(0x33FFFFFF),
                              secondaryActiveColor:
                                  progressColor.withValues(alpha: .4),
                              onChangeStart: _beginSeek,
                              onChanged: _clockPlayer.state.duration <=
                                          Duration.zero ||
                                      widget.loading
                                  ? null
                                  : _previewSeek,
                              onChangeEnd: (value) =>
                                  unawaited(_finishSeek(value)),
                            ),
                          )));
                }),
              ),
            Row(key: const ValueKey('recording-bottom-controls'), children: [
              ValueListenableBuilder<bool>(
                valueListenable: _playingPresentation,
                builder: (context, playing, _) => iconButton(
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: widget.loading ? null : _togglePlayback,
                    icon: playing ? Icons.pause : Icons.play_arrow,
                    size: 20,
                    width: 42,
                    height: 34),
              ),
              if (!widget.isLive) time,
              if (widget.isLive) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: narrow ? 64 : 88),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('● 直播中',
                        key: const ValueKey('recording-live-label'),
                        maxLines: 1,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 12)),
                  ),
                ),
                iconButton(
                    tooltip: '回到直播',
                    onPressed: widget.loading ? null : widget.onReconnect,
                    icon: Icons.refresh),
              ],
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

/// Shows a quality tier derived from the decoded frame's shorter edge.
///
/// Uses PiliPlus-style short labels, with local pixel thresholds because VOD
/// does not provide a platform quality ID. Rotating a video keeps its tier.
/// WebRTC renderers and media players share this presentation.
class RecordingVideoResolutionLabel extends StatelessWidget {
  const RecordingVideoResolutionLabel({
    super.key,
    required this.width,
    required this.height,
  });

  final int? width;
  final int? height;

  @override
  Widget build(BuildContext context) {
    final width = this.width;
    final height = this.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return const SizedBox.shrink();
    }
    final shortEdge = math.min(width, height);
    final label = switch (shortEdge) {
      >= 4320 => '8K',
      >= 2160 => '4K',
      >= 1440 => '2K',
      >= 1080 => '1080P',
      >= 720 => '720P',
      >= 480 => '480P',
      >= 360 => '360P',
      >= 240 => '240P',
      _ => '${shortEdge}P',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(label,
          key: const ValueKey('recording-quality-label'),
          maxLines: 1,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }
}

class _RecordingPlayerResolutionLabel extends StatefulWidget {
  const _RecordingPlayerResolutionLabel({required this.player});

  final Player player;

  @override
  State<_RecordingPlayerResolutionLabel> createState() =>
      _RecordingPlayerResolutionLabelState();
}

class _RecordingPlayerResolutionLabelState
    extends State<_RecordingPlayerResolutionLabel> {
  final _subscriptions = <StreamSubscription<int?>>[];
  int? _width;
  int? _height;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final revision = ++_revision;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _width = widget.player.state.width;
    _height = widget.player.state.height;
    _subscriptions.add(widget.player.stream.width.listen((width) {
      if (mounted && revision == _revision && width != _width) {
        setState(() => _width = width);
      }
    }));
    _subscriptions.add(widget.player.stream.height.listen((height) {
      if (mounted && revision == _revision && height != _height) {
        setState(() => _height = height);
      }
    }));
  }

  @override
  void didUpdateWidget(covariant _RecordingPlayerResolutionLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _bind();
  }

  @override
  void dispose() {
    _revision++;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RecordingVideoResolutionLabel(width: _width, height: _height);
}

String _durationText(Duration duration) {
  final seconds = math.max(0, duration.inSeconds);
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:$minutes:$remainder'
      : '$minutes:$remainder';
}
