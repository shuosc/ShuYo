import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_live_stream_proxy.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_playback_status.dart';
import 'recording_player_cache.dart';
import 'recording_status_icon.dart';
import 'recording_secondary_video.dart';
import 'recording_video_controls.dart';

export 'recording_video_controls.dart';

/// A route for account-authorized live lessons and recordings.
///
/// Sources are requested again for every lesson change and retry. Signed URLs
/// stay in this route's memory and never become widget keys or stored history.
class RecordingPlayerPage extends StatefulWidget {
  const RecordingPlayerPage({
    super.key,
    required this.course,
    this.lessons = const [],
    this.initialLesson,
    this.loadPlayback,
    this.repository,
    this.onSessionExpired,
    this.playerFactory,
    this.videoControllerFactory,
  });

  final VodCourse course;
  final List<VodLesson> lessons;
  final VodLesson? initialLesson;
  final Future<VodPlayback> Function(VodLesson)? loadPlayback;
  final VodRepository? repository;
  final Future<bool> Function()? onSessionExpired;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final VideoController Function(Player)? videoControllerFactory;

  @override
  State<RecordingPlayerPage> createState() => _RecordingPlayerPageState();
}

enum _PlaybackFailure { session, permission, network, unavailable, media }

class _RecordingPlayerPageState extends State<RecordingPlayerPage>
    with WidgetsBindingObserver {
  final _videoKey = GlobalKey<VideoState>();
  final _controlsRevision = ValueNotifier(0);
  Player? _player;
  Player? _timelinePlayer;
  VideoController? _videoController;
  VideoController? _hostVideoController;
  StreamSubscription<String>? _errorSubscription;
  late VodLesson _lesson = widget.initialLesson ??
      const VodLesson(id: 0, teachingClassId: 0, name: '', isPlayable: false);
  late List<VodLesson> _catalog = widget.lessons;
  VodLiveStreamProxy? _liveProxy;
  Timer? _heartbeatTimer;
  Timer? _liveEndTimer;
  bool _foreground = true;
  bool _resumeLive = false;
  bool _heartbeatPending = false;
  bool _catalogLoading = false;
  int _catalogRevision = 0;
  VodPlayback? _playback;
  int _viewIndex = 0;
  int? _loadedLessonId;
  int _loadRevision = 0;
  int? _openingMediaRevision;
  Future<void> _mediaQueue = Future<void>.value();
  bool _loading = true;
  bool _recovering = false;
  bool _fullscreenActive = false;
  bool _episodePanelVisible = false;
  bool _dualEnabled = false;
  Player? _secondaryPlayer;
  VideoController? _secondaryController;
  final _syncSubscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<String>? _secondaryErrorSubscription;
  Future<void> _secondaryQueue = Future<void>.value();
  int _secondaryRevision = 0;
  bool _secondaryLoading = false;
  bool _secondaryWaitingForMain = false;
  bool _secondaryFailed = false;
  int? _secondaryViewIndex;
  int? _pendingViewIndex;
  bool _swappingViews = false;
  bool _seekingPlayers = false;
  bool _syncingSecondary = false;
  Completer<void>? _secondarySyncCompletion;
  bool _secondarySyncPending = false;
  String _aspect = '自动';
  String _preferredView = '教室';
  _PlaybackFailure? _failure;
  String? _failureMessage;

  List<VodLesson> get _lessons => _catalog
      .where((lesson) =>
          (lesson.isPlayable ||
              lesson.isGenerating ||
              lesson.isLive ||
              lesson.isListed) &&
          lesson.teachingClassId == widget.course.teachingClassId)
      .toList(growable: false)
    ..sort((first, second) {
      final time = (second.beginTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(first.beginTime?.millisecondsSinceEpoch ?? 0);
      return time == 0 ? second.id.compareTo(first.id) : time;
    });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isMobile) {
      unawaited(SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]));
    }
    final initial = widget.initialLesson ?? widget.course.liveLesson;
    if (initial != null &&
        initial.canPlay &&
        initial.teachingClassId == widget.course.teachingClassId) {
      _lesson = initial;
      if (!_catalog.any((lesson) =>
          lesson.id == initial.id && lesson.isLive == initial.isLive)) {
        _catalog = [initial, ..._catalog];
      }
      unawaited(_loadLesson(initial));
      if (widget.repository != null) unawaited(_loadCatalog());
    } else {
      unawaited(
          widget.repository == null ? _loadLesson(_lesson) : _loadCatalog());
    }
  }

  Future<void> _loadCatalog({bool forceRefresh = false}) async {
    final repository = widget.repository;
    if (repository == null || _catalogLoading) return;
    final revision = ++_catalogRevision;
    _publish(() => _catalogLoading = true);
    try {
      final lessons = await repository.loadCourseLessons(widget.course,
          forceRefresh: forceRefresh);
      if (!mounted || revision != _catalogRevision) return;
      _publish(() {
        _catalog = _loading &&
                _lesson.canPlay &&
                !lessons.any((lesson) =>
                    lesson.id == _lesson.id && lesson.isLive == _lesson.isLive)
            ? [_lesson, ...lessons]
            : lessons;
        _catalogLoading = false;
      });
      final ordered = _lessons;
      final current = ordered
          .where((lesson) =>
              lesson.id == _lesson.id &&
              lesson.isLive == _lesson.isLive &&
              lesson.canPlay)
          .firstOrNull;
      final selected = current ??
          ordered.where((lesson) => lesson.isLiveAvailable).firstOrNull ??
          ordered.where((lesson) => lesson.canPlay).firstOrNull;
      if (selected != null) {
        if (current == null ||
            !_loading && (_playback == null || _failure != null)) {
          await _loadLesson(selected);
        }
      } else {
        await _player?.pause();
        _stopLiveTimers();
        _publish(() {
          _loading = false;
          _failure = null;
          _playback = null;
        });
      }
    } on Object catch (error) {
      if (!mounted || revision != _catalogRevision) return;
      if ((_playback != null || _loading && _lesson.canPlay) &&
          error is! VodSessionExpiredException &&
          error is! VodPermissionException) {
        _publish(() => _catalogLoading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('选集刷新失败，请稍后下拉重试')));
        return;
      }
      _stopLiveTimers();
      _loadRevision++;
      _secondaryRevision++;
      await _player?.pause();
      await _secondaryPlayer?.pause();
      if (!mounted || revision != _catalogRevision) return;
      _publish(() {
        _catalogLoading = false;
        _loading = false;
        _failure = switch (error) {
          VodSessionExpiredException() => _PlaybackFailure.session,
          VodPermissionException() => _PlaybackFailure.permission,
          VodNetworkException() => _PlaybackFailure.network,
          _ => _PlaybackFailure.unavailable,
        };
      });
    }
  }

  void _stopLiveTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _liveEndTimer?.cancel();
    _liveEndTimer = null;
  }

  Future<void> _heartbeat(int revision) async {
    if (!_foreground ||
        revision != _loadRevision ||
        _heartbeatPending ||
        _player?.state.playing != true) {
      return;
    }
    _heartbeatPending = true;
    try {
      await widget.repository?.keepLiveAlive(widget.course, _lesson);
    } on VodSessionExpiredException {
      if (mounted && revision == _loadRevision) {
        _stopLiveTimers();
        await _player?.pause();
        _publish(() => _failure = _PlaybackFailure.session);
      }
    } on VodPermissionException {
      if (mounted && revision == _loadRevision) {
        _stopLiveTimers();
        await _player?.pause();
        _publish(() => _failure = _PlaybackFailure.permission);
      }
    } on Object {
      return;
    } finally {
      _heartbeatPending = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _resumeLive =
          _resumeLive || _lesson.isLive && (_player?.state.playing ?? false);
      _stopLiveTimers();
      unawaited(_player?.pause());
      unawaited(_secondaryPlayer?.pause());
    } else if (_resumeLive) {
      _resumeLive = false;
      unawaited(_loadLesson(_lesson));
    }
  }

  @override
  void dispose() {
    _loadRevision++;
    _catalogRevision++;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    WidgetsBinding.instance.removeObserver(this);
    _stopLiveTimers();
    unawaited(_liveProxy?.dispose());
    unawaited(_restoreOrientation());
    for (final subscription in _syncSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_releasePlayer(_secondaryPlayer, _secondaryErrorSubscription));
    // Video owns wake lock and application lifecycle handling. The route owns
    // Player and releases its native decoder, streams and network requests.
    unawaited(_releasePlayer(_player, _errorSubscription));
    _controlsRevision.dispose();
    super.dispose();
  }

  void _publish(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _controlsRevision.value++;
  }

  bool _validLesson(VodLesson lesson) =>
      lesson.canPlay &&
      lesson.teachingClassId == widget.course.teachingClassId &&
      _catalog.any((item) =>
          item.id == lesson.id && item.isLive == lesson.isLive && item.canPlay);

  Future<void> _loadLesson(VodLesson lesson, {bool resume = false}) async {
    final revision = ++_loadRevision;
    _openingMediaRevision = null;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    _secondaryLoading = false;
    _secondaryWaitingForMain = false;
    _pendingViewIndex = null;
    unawaited(_secondaryPlayer?.pause());
    if (lesson.id != _lesson.id) _preferredView = '教室';
    _stopLiveTimers();
    final oldProxy = _liveProxy;
    _liveProxy = null;
    await oldProxy?.dispose();
    if (!mounted || revision != _loadRevision) return;
    final oldPosition =
        resume && _loadedLessonId == lesson.id ? _player?.state.position : null;
    _publish(() {
      _lesson = lesson;
      _loading = true;
      _failure = null;
      _failureMessage = null;
      _playback = null;
    });
    if (!_validLesson(lesson)) {
      _publish(() {
        _loading = false;
        _failure = _PlaybackFailure.unavailable;
      });
      return;
    }
    try {
      await _player?.pause();
      final playback = await (widget.loadPlayback?.call(lesson) ??
          widget.repository!
              .preparePlayback(course: widget.course, lesson: lesson));
      if (!mounted || revision != _loadRevision) return;
      if (playback.lessonId != lesson.id ||
          playback.teachingClassId != widget.course.teachingClassId ||
          playback.views.isEmpty ||
          playback.isLive != lesson.isLive ||
          playback.views.any((view) =>
              !const ['http', 'https'].contains(view.url.scheme) ||
              view.url.host.isEmpty ||
              view.url.userInfo.isNotEmpty)) {
        _publish(() {
          _loading = false;
          _failure = _PlaybackFailure.unavailable;
        });
        return;
      }
      final classroom =
          playback.views.where((view) => view.viewNumber == 1).firstOrNull ??
              playback.views.where((view) => view.viewNumber != 5).firstOrNull;
      final ppt =
          playback.views.where((view) => view.viewNumber == 5).firstOrNull;
      final views = <VodView>[
        if (classroom != null)
          VodView(
              viewNumber: classroom.viewNumber,
              url: classroom.url,
              httpHeaders: classroom.httpHeaders,
              displayLabel: '教室'),
        if (ppt != null)
          VodView(
              viewNumber: ppt.viewNumber,
              url: ppt.url,
              httpHeaders: ppt.httpHeaders,
              displayLabel: 'PPT'),
      ];
      final selected = views.indexWhere((view) => view.label == _preferredView);
      _publish(() {
        _playback = VodPlayback(
            lessonId: playback.lessonId,
            teachingClassId: playback.teachingClassId,
            title: playback.title,
            views: views,
            lastPosition: playback.lastPosition,
            voiceChannel: playback.voiceChannel,
            isLive: playback.isLive,
            description: playback.description);
        _viewIndex = selected < 0 ? 0 : selected;
      });
      await _openView(
        _viewIndex,
        revision: revision,
        position: lesson.isLive ? null : oldPosition ?? playback.lastPosition,
      );
    } on Object catch (error) {
      if (!mounted || revision != _loadRevision) return;
      debugPrint(
          'ShuYoVOD playback failure: ${error.runtimeType}, status=${error is VodApiException ? error.statusCode : null}');
      _publish(() {
        _failureMessage =
            error is VodLiveUnavailableException ? error.message : null;
        _loading = false;
        _failure = switch (error) {
          VodSessionExpiredException() => _PlaybackFailure.session,
          VodPermissionException() => _PlaybackFailure.permission,
          VodNetworkException() => _PlaybackFailure.network,
          _ => _PlaybackFailure.unavailable,
        };
      });
    }
  }

  Future<void> _openView(
    int index, {
    required int revision,
    Duration? position,
    bool play = true,
  }) async {
    final playback = _playback;
    if (playback == null || index < 0 || index >= playback.views.length) return;
    final view = playback.views[index];
    _publish(() {
      _viewIndex = index;
      _loading = true;
      _failure = null;
    });
    // Native opens are serialized as well as guarded by revision: a late
    // response or camera change cannot replace the user's newer selection.
    _mediaQueue = _mediaQueue.then((_) async {
      if (!mounted || revision != _loadRevision) return;
      var videoReady = false;
      try {
        var player = _player;
        if (player == null) {
          player = widget.playerFactory?.call() ??
              Player(
                configuration: const PlayerConfiguration(title: 'ShuYo 课程视频'),
              );
          _player = player;
          _videoController = widget.videoControllerFactory?.call(player) ??
              VideoController(player);
          _hostVideoController ??= _videoController;
          final created = player;
          _errorSubscription =
              player.stream.error.listen((_) => _onPlayerError(created));
          for (final stream in <Stream<dynamic>>[
            player.stream.position,
            player.stream.playing,
            player.stream.buffering,
            player.stream.rate
          ]) {
            _syncSubscriptions
                .add(stream.listen((_) => unawaited(_alignSecondary())));
          }
          _watchCacheRate(player);
          _publish(() {});
        }
        // VideoController initializes on the next frame. Publishing the Video
        // first lets that frame run; observing its future catches native
        // renderer failures before an audio-only/blank player is presented.
        await _videoController!.platform.future
            .timeout(const Duration(seconds: 20));
        if (!mounted || revision != _loadRevision) return;
        videoReady = true;
        final rate = player.state.rate;
        await configureRecordingPlayerCache(
          player,
          isLive: playback.isLive,
          rate: playback.isLive ? 1 : rate,
        );
        if (!mounted || revision != _loadRevision) return;
        var mediaUrl = view.url;
        if (playback.isLive && widget.repository != null) {
          _liveProxy ??= VodLiveStreamProxy(
            useWebVpn: widget.repository!.useWebVpn,
            headersLoader: widget.repository!.mediaHeadersFor,
          );
          mediaUrl = await _liveProxy!.open(view.url);
        }
        _openingMediaRevision = revision;
        _timelinePlayer = player;
        await player
            .open(
              Media(
                mediaUrl.toString(),
                httpHeaders: playback.isLive && _liveProxy != null
                    ? const {}
                    : view.httpHeaders,
                start: position != null && position > Duration.zero
                    ? position
                    : null,
              ),
              play: play && _foreground,
            )
            .timeout(const Duration(seconds: 25));
        if (_openingMediaRevision == revision) _openingMediaRevision = null;
        if (!mounted || revision != _loadRevision) return;
        if (playback.isLive || rate != 1) {
          await player.setRate(playback.isLive ? 1 : rate);
        }
        if (playback.isLive && _foreground) {
          unawaited(_heartbeat(revision));
          _heartbeatTimer = Timer.periodic(const Duration(seconds: 60),
              (_) => unawaited(_heartbeat(revision)));
          final end = _lesson.liveEndTime ?? _lesson.endTime;
          if (end != null) {
            _liveEndTimer = Timer(
                end.difference(DateTime.now()).isNegative
                    ? Duration.zero
                    : end.difference(DateTime.now()), () {
              _stopLiveTimers();
              unawaited(_player?.pause());
              unawaited(_secondaryPlayer?.pause());
              if (mounted) {
                _publish(() => _failure = _PlaybackFailure.unavailable);
              }
              unawaited(_loadCatalog(forceRefresh: true));
            });
          }
        }
        _publish(() {
          _loadedLessonId = playback.lessonId;
          _loading = false;
        });
        unawaited(_prewarmSecondary(revision));
      } on Object {
        if (_openingMediaRevision == revision) _openingMediaRevision = null;
        if (!mounted || revision != _loadRevision) return;
        if (!videoReady) {
          unawaited(_releasePlayer(_player, _errorSubscription));
          _player = null;
          _videoController = null;
          _hostVideoController = null;
          _errorSubscription = null;
          _loadedLessonId = null;
        }
        _publish(() {
          _loading = false;
          _failure = _PlaybackFailure.media;
        });
      }
    });
    await _mediaQueue;
  }

  Future<void> _releasePlayer(
    Player? player,
    StreamSubscription<String>? errorSubscription,
  ) async {
    try {
      await errorSubscription?.cancel();
      await player?.dispose();
    } on Object {
      // A failed native initialization must not turn leaving/retrying the
      // route into an uncaught asynchronous exception.
    }
  }

  Future<void> _waitForVideoOutput(VideoController controller) async {
    final output = await controller.platform.future;
    await controller.waitUntilFirstFrameRendered;
    bool ready() =>
        output.id.value != null &&
        (output.rect.value?.width ?? 0) > 1 &&
        (output.rect.value?.height ?? 0) > 1;
    if (ready()) return;
    final completion = Completer<void>();
    void check() {
      if (!completion.isCompleted && ready()) completion.complete();
    }

    output.id.addListener(check);
    output.rect.addListener(check);
    try {
      check();
      await completion.future.timeout(const Duration(seconds: 20));
    } finally {
      output.id.removeListener(check);
      output.rect.removeListener(check);
    }
  }

  Future<void> _prewarmSecondary(int revision) async {
    final controller = _videoController;
    if (controller == null || (_playback?.views.length ?? 0) < 2) return;
    _publish(() {
      _secondaryWaitingForMain = true;
      _secondaryFailed = false;
    });
    try {
      await _waitForVideoOutput(controller)
          .timeout(const Duration(seconds: 20));
    } on Object {
      if (mounted && revision == _loadRevision) {
        _publish(() {
          _secondaryWaitingForMain = false;
          _secondaryFailed = true;
        });
      }
      return;
    }
    if (!mounted || revision != _loadRevision) return;
    _publish(() => _secondaryWaitingForMain = false);
    await _openSecondary();
  }

  bool get _viewsAligned {
    final primary = _player;
    final secondary = _secondaryPlayer;
    return primary != null &&
        secondary != null &&
        !primary.state.buffering &&
        !secondary.state.buffering &&
        (_lesson.isLive ||
            (primary.state.position - secondary.state.position)
                    .inMilliseconds
                    .abs() <=
                250);
  }

  Future<void> _selectView(int index) async {
    final playback = _playback;
    if (playback == null ||
        index < 0 ||
        index >= playback.views.length ||
        _loading ||
        _swappingViews) {
      return;
    }
    if (index == _viewIndex) {
      _pendingViewIndex = null;
      return;
    }
    if (_secondaryLoading ||
        _secondaryWaitingForMain ||
        _secondaryFailed ||
        _secondaryViewIndex != index ||
        _secondaryPlayer == null ||
        _secondaryController == null) {
      _pendingViewIndex = index;
      return;
    }
    final primary = _player!;
    final secondary = _secondaryPlayer!;
    final revision = _loadRevision;
    _swappingViews = true;
    try {
      await _alignSecondary(allowDuringSwap: true);
      if (!mounted || revision != _loadRevision || _secondaryFailed) return;
      if (!_viewsAligned) {
        _pendingViewIndex = index;
        return;
      }
      final volume = primary.state.volume;
      await primary.setVolume(0);
      if (!mounted || revision != _loadRevision) {
        if (mounted) await primary.setVolume(volume);
        return;
      }
      _publish(() {
        final controller = _videoController;
        final errorSubscription = _errorSubscription;
        _player = secondary;
        _secondaryPlayer = primary;
        _videoController = _secondaryController;
        _secondaryController = controller;
        _errorSubscription = _secondaryErrorSubscription;
        _secondaryErrorSubscription = errorSubscription;
        _secondaryViewIndex = _viewIndex;
        _viewIndex = index;
        _preferredView = playback.views[index].label;
        _pendingViewIndex = null;
      });
      await secondary.setVolume(volume);
    } on Object {
      if (mounted && revision == _loadRevision) {
        _publish(() => _failure = _PlaybackFailure.media);
      }
    } finally {
      _swappingViews = false;
    }
  }

  void _onPlayerError(Player source) {
    if (!mounted) return;
    if (identical(source, _player) &&
        (!_loading || _openingMediaRevision == _loadRevision)) {
      _loadRevision++;
      _openingMediaRevision = null;
      _secondaryRevision++;
      _stopLiveTimers();
      unawaited(_secondaryPlayer?.pause());
      _publish(() {
        _loading = false;
        _failure = _PlaybackFailure.media;
      });
    } else if (identical(source, _secondaryPlayer)) {
      _publish(() => _secondaryFailed = true);
      unawaited(source.pause());
    }
  }

  void _watchCacheRate(Player player) {
    _syncSubscriptions.add(player.stream.rate.listen((rate) {
      final playback = _playback;
      if (!mounted ||
          _loading ||
          playback == null ||
          playback.isLive ||
          (!identical(player, _player) &&
              !identical(player, _secondaryPlayer))) {
        return;
      }
      unawaited(
          configureRecordingPlayerCache(player, isLive: false, rate: rate));
    }));
  }

  Future<void> _seekPlayers(Duration position) async {
    final primary = _player;
    final secondary = _secondaryPlayer;
    if (primary == null || _lesson.isLive || _loading) return;
    _seekingPlayers = true;
    try {
      await Future.wait([
        primary.seek(position),
        if (secondary != null &&
            _secondaryViewIndex != null &&
            !_secondaryLoading &&
            !_secondaryFailed)
          secondary.seek(position),
      ]);
    } finally {
      _seekingPlayers = false;
    }
  }

  Future<void> _retry() async {
    if (_loading || _recovering) return;
    if (_failure == _PlaybackFailure.session) {
      final recover = widget.onSessionExpired;
      if (recover == null) return;
      _publish(() => _recovering = true);
      var recovered = false;
      try {
        recovered = await recover();
      } on Object {
        // Recovery details may contain credentials or signed URLs.
      }
      if (!mounted) return;
      _publish(() => _recovering = false);
      if (!recovered) return;
    }
    if (widget.repository != null && (_lesson.id == 0 || _catalog.isEmpty)) {
      await _loadCatalog(forceRefresh: true);
    } else {
      await _loadLesson(_lesson, resume: !_lesson.isLive);
    }
  }

  Future<void> _reloadPlayback() async {
    if (_recovering) return;
    if (_failure != null) return _retry();
    if (_validLesson(_lesson)) {
      await _loadLesson(_lesson, resume: !_lesson.isLive);
    } else if (widget.repository != null && !_catalogLoading) {
      await _loadCatalog(forceRefresh: true);
    }
  }

  Future<void> _enterFullscreen() async {
    _fullscreenActive = true;
    await defaultEnterNativeFullscreen();
  }

  Future<void> _exitFullscreen() async {
    if (_episodePanelVisible) return;
    await _performExitFullscreen();
  }

  Future<void> _performExitFullscreen() async {
    _fullscreenActive = false;
    await defaultExitNativeFullscreen();
    if (_isMobile) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  bool get _isMobile =>
      !kIsWeb &&
      const [TargetPlatform.android, TargetPlatform.iOS]
          .contains(defaultTargetPlatform);

  Future<void> _restoreOrientation() async {
    if (_fullscreenActive) await _performExitFullscreen();
    if (_isMobile) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const []);
    }
  }

  void _changeAspect(String value) {
    _publish(() => _aspect = value);
    _videoKey.currentState?.update(
      aspectRatio: switch (value) {
        '4:3' => 4 / 3,
        '16:9' => 16 / 9,
        _ => _player?.state.width != null && (_player?.state.height ?? 0) > 0
            ? _player!.state.width! / _player!.state.height!
            : 16 / 9
      },
      fit: switch (value) {
        '填充' => BoxFit.fill,
        '裁剪' => BoxFit.cover,
        _ => BoxFit.contain
      },
    );
  }

  void _setDualEnabled(bool value) {
    _publish(() => _dualEnabled = value);
    if (value &&
        !_secondaryLoading &&
        !_secondaryWaitingForMain &&
        (_secondaryFailed ||
            _secondaryViewIndex != (_viewIndex == 0 ? 1 : 0))) {
      unawaited(_openSecondary());
    }
  }

  Future<void> _openSecondary() async {
    final playback = _playback;
    if (!_foreground ||
        playback == null ||
        playback.views.length < 2 ||
        _failure != null) {
      await _secondaryPlayer?.pause();
      return;
    }
    final index = _viewIndex == 0 ? 1 : 0;
    if (_secondaryViewIndex == index && !_secondaryFailed ||
        _secondaryLoading) {
      return;
    }
    final revision = ++_secondaryRevision;
    final view = playback.views[index];
    _publish(() {
      _secondaryLoading = true;
      _secondaryFailed = false;
    });
    _secondaryQueue = _secondaryQueue.then((_) async {
      if (!mounted || revision != _secondaryRevision) return;
      try {
        var secondary = _secondaryPlayer;
        if (secondary == null) {
          secondary = widget.playerFactory?.call() ??
              Player(
                  configuration: const PlayerConfiguration(title: 'ShuYo 副视角'));
          _secondaryPlayer = secondary;
          _secondaryController =
              widget.videoControllerFactory?.call(secondary) ??
                  VideoController(secondary);
          final created = secondary;
          _secondaryErrorSubscription =
              secondary.stream.error.listen((_) => _onPlayerError(created));
          for (final stream in <Stream<dynamic>>[
            secondary.stream.position,
            secondary.stream.playing,
            secondary.stream.buffering,
            secondary.stream.rate,
          ]) {
            _syncSubscriptions
                .add(stream.listen((_) => unawaited(_alignSecondary())));
          }
          _watchCacheRate(secondary);
          _publish(() {});
        }
        await secondary.setVolume(0);
        await _secondaryController!.platform.future
            .timeout(const Duration(seconds: 20));
        if (!mounted || revision != _secondaryRevision) return;
        await configureRecordingPlayerCache(
          secondary,
          isLive: playback.isLive,
          rate: playback.isLive ? 1 : _player?.state.rate ?? 1,
        );
        if (!mounted || revision != _secondaryRevision) return;
        final url = playback.isLive && _liveProxy != null
            ? await _liveProxy!.open(view.url)
            : view.url;
        await secondary
            .open(
                Media(url.toString(),
                    httpHeaders: playback.isLive && _liveProxy != null
                        ? const {}
                        : view.httpHeaders,
                    start: playback.isLive ? null : _player?.state.position),
                play: _foreground && (_player?.state.playing ?? false))
            .timeout(const Duration(seconds: 25));
        if (!mounted || revision != _secondaryRevision) return;
        await secondary.setRate(_player?.state.rate ?? 1);
        await _waitForVideoOutput(_secondaryController!)
            .timeout(const Duration(seconds: 20));
        if (!mounted || revision != _secondaryRevision) {
          await secondary.pause();
          return;
        }
        _publish(() {
          _secondaryViewIndex = index;
          _secondaryLoading = false;
        });
        await _alignSecondary();
        final pending = _pendingViewIndex;
        if (pending != null && mounted && revision == _secondaryRevision) {
          await _selectView(pending);
        }
      } on Object {
        if (mounted && revision == _secondaryRevision) {
          _publish(() {
            _secondaryLoading = false;
            _secondaryFailed = true;
          });
        }
      }
    });
    await _secondaryQueue;
  }

  Future<void> _alignSecondary({bool allowDuringSwap = false}) async {
    if (_syncingSecondary) {
      _secondarySyncPending = true;
      await _secondarySyncCompletion?.future;
      if (allowDuringSwap) {
        await _alignSecondary(allowDuringSwap: true);
      }
      return;
    }
    final primary = _player;
    final secondary = _secondaryPlayer;
    final revision = _secondaryRevision;
    if (_secondaryLoading ||
        _secondaryFailed ||
        !_foreground ||
        _loading ||
        (_swappingViews && !allowDuringSwap) ||
        _seekingPlayers ||
        _secondaryViewIndex == null ||
        primary == null ||
        secondary == null) {
      return;
    }
    _syncingSecondary = true;
    final completion = Completer<void>();
    _secondarySyncCompletion = completion;
    bool stillCurrent() =>
        mounted &&
        revision == _secondaryRevision &&
        identical(primary, _player) &&
        identical(secondary, _secondaryPlayer) &&
        _foreground &&
        !_loading;
    try {
      final timeline = _timelinePlayer ?? primary;
      final follower = identical(timeline, primary) ? secondary : primary;
      if (!_lesson.isLive &&
          !timeline.state.buffering &&
          !follower.state.buffering &&
          (timeline.state.position - follower.state.position)
                  .inMilliseconds
                  .abs() >
              250) {
        await follower.seek(timeline.state.position);
        if (!stillCurrent()) return;
      }
      if (secondary.state.rate != primary.state.rate) {
        await secondary.setRate(primary.state.rate);
        if (!stillCurrent()) return;
      }
      if (!stillCurrent()) return;
      if (primary.state.playing != secondary.state.playing) {
        if (primary.state.playing) {
          await secondary.play();
        } else {
          await secondary.pause();
        }
      }
    } on Object {
      if (mounted) _publish(() => _secondaryFailed = true);
    } finally {
      _syncingSecondary = false;
      _secondarySyncCompletion = null;
      completion.complete();
      if (_secondarySyncPending) {
        _secondarySyncPending = false;
        unawaited(_alignSecondary());
      }
      final pending = _pendingViewIndex;
      if (pending != null && !_swappingViews && _viewsAligned) {
        unawaited(_selectView(pending));
      }
    }
  }

  Widget _secondaryView() => ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        if (_secondaryController != null)
          RecordingSecondaryVideo(controller: _secondaryController!),
        if (_secondaryLoading || _secondaryWaitingForMain)
          const RecordingPlaybackLoading(compact: true),
        if (_secondaryFailed)
          Center(
              child: const Icon(Icons.videocam_off_outlined,
                  color: Colors.white54)),
      ]));

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
          bottom: false,
          child: Material(
              color: colors.surface,
              child: LayoutBuilder(builder: (context, constraints) {
                final video = ColoredBox(
                  color: Colors.black,
                  child: _videoController == null
                      ? AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(children: [
                            Positioned.fill(child: _placeholder()),
                            Align(
                                alignment: Alignment.topLeft,
                                child: IconButton(
                                    tooltip: '返回课程列表',
                                    onPressed: () =>
                                        Navigator.of(context).maybePop(),
                                    icon: const Icon(Icons.arrow_back,
                                        color: Colors.white))),
                          ]))
                      : Video(
                          key: _videoKey,
                          controller: _hostVideoController!,
                          aspectRatio: 16 / 9,
                          onEnterFullscreen: _enterFullscreen,
                          onExitFullscreen: _exitFullscreen,
                          controls: (state) => ValueListenableBuilder<int>(
                            valueListenable: _controlsRevision,
                            builder: (context, _, __) => RecordingVideoControls(
                              state: state,
                              fullscreen:
                                  FullscreenInheritedWidget.maybeOf(context) !=
                                      null,
                              player: _player!,
                              onSeek: _seekPlayers,
                              primaryView:
                                  Stack(fit: StackFit.expand, children: [
                                if (_secondaryController != null)
                                  RecordingSecondaryVideo(
                                      controller: _secondaryController!),
                                RecordingSecondaryVideo(
                                  controller: _videoController!,
                                  aspectRatio: switch (_aspect) {
                                    '4:3' => 4 / 3,
                                    '16:9' => 16 / 9,
                                    _ => null,
                                  },
                                  fit: switch (_aspect) {
                                    '填充' => BoxFit.fill,
                                    '裁剪' => BoxFit.cover,
                                    _ => BoxFit.contain,
                                  },
                                ),
                              ]),
                              title: widget.course.name,
                              onBack: () => Navigator.of(context).maybePop(),
                              onEpisodePanelVisibilityChanged: (visible) =>
                                  _episodePanelVisible = visible,
                              lessons: _lessons,
                              selectedLessonId: _lesson.id,
                              onLessonSelected: (lesson) =>
                                  unawaited(_loadLesson(lesson)),
                              dualEnabled: _dualEnabled,
                              onDualChanged: kIsWeb ? null : _setDualEnabled,
                              secondaryView: _secondaryView(),
                              secondaryLabel: (_playback?.views.length ?? 0) > 1
                                  ? _playback!
                                      .views[_viewIndex == 0 ? 1 : 0].label
                                  : '',
                              onSwapViews: () => unawaited(
                                  _selectView(_viewIndex == 0 ? 1 : 0)),
                              aspect: _aspect,
                              onAspectChanged: _changeAspect,
                              loading: _loading,
                              isLive: _lesson.isLive,
                              onReconnect: () =>
                                  unawaited(_loadLesson(_lesson)),
                              onReload: () => unawaited(_reloadPlayback()),
                              failure: _failure == null ? null : _placeholder(),
                              views: _playback?.views ?? const [],
                              selectedView: _viewIndex,
                            ),
                          ),
                        ),
                );
                final list = _lessonList(colors);
                if (constraints.maxWidth >= 1000) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child:
                            ListView(children: [video, _lessonHeading(colors)]),
                      ),
                      SizedBox(width: 360, child: list),
                    ],
                  );
                }
                return Column(children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: math.max(100, constraints.maxHeight * .6),
                    ),
                    child: AspectRatio(aspectRatio: 16 / 9, child: video),
                  ),
                  Expanded(child: list),
                ]);
              }))),
    );
  }

  Widget _placeholder() {
    if (_loading || _recovering || _catalogLoading && _catalog.isEmpty) {
      return RecordingPlaybackLoading(
        onRetry: _validLesson(_lesson) && !_recovering
            ? () => unawaited(_reloadPlayback())
            : null,
      );
    }
    if (_failure == null && _playback == null) {
      return RecordingPlaybackMessage(
        icon: Icons.ondemand_video_outlined,
        message: _lessons.any((lesson) => lesson.isGenerating)
            ? '回放生成中，生成后可观看'
            : '暂无可观看的视频',
        action: widget.repository == null
            ? null
            : TextButton.icon(
                onPressed: () => unawaited(_loadCatalog(forceRefresh: true)),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新选集'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
      );
    }
    final session = _failure == _PlaybackFailure.session;
    final message = _failureMessage ??
        switch (_failure) {
          _PlaybackFailure.session => '校园账户登录已失效，请重新登录。',
          _PlaybackFailure.permission =>
            _lesson.isLive ? '当前账号没有这节直播的观看权限。' : '当前账号没有这节录播的观看权限。',
          _PlaybackFailure.network => '暂时无法连接录播平台，请检查网络后重试。',
          _PlaybackFailure.media => '视频暂时无法播放，可刷新播放地址后重试。',
          _ => _lesson.isLive ? '直播暂时无法观看或已结束，请刷新重试。' : '这节录播暂时无法观看，请稍后重试。',
        };
    return RecordingPlaybackMessage(
      icon: Icons.error_outline_rounded,
      message: message,
      action: session && widget.onSessionExpired == null
          ? null
          : TextButton.icon(
              onPressed: () => unawaited(_retry()),
              icon: Icon(session ? Icons.login : Icons.refresh, size: 18),
              label: Text(session ? '重新登录' : '重试'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
    );
  }

  Widget _lessonHeading(ShuYoColors colors) {
    final meta = [
      if (widget.course.teacherLabel.isNotEmpty) widget.course.teacherLabel,
      _lessonDate(_lesson),
      if (_lesson.classroom.isNotEmpty) _lesson.classroom,
    ].where((item) => item.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('课程介绍', style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        const SizedBox(height: 6),
        Text(widget.course.name,
            style: ShuYoTextStyles.title(color: colors.textPrimary)),
        const SizedBox(height: 6),
        Text(meta, style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        if (widget.course.code.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('课程代码 · ${widget.course.code}',
              style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        ],
        if (_playback?.description.isNotEmpty ?? false) ...[
          const SizedBox(height: 10),
          Text(_playback!.description,
              style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary)),
        ],
      ]),
    );
  }

  Widget _lessonList(ShuYoColors colors) {
    final lessons = _lessons;
    final content = ListView(
      key: const ValueKey('course-player-episodes'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _lessonHeading(colors),
        if (_catalogLoading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('选集（${lessons.length}）',
              style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary)),
        ),
        if (lessons.isEmpty && !_catalogLoading)
          Padding(
              padding: const EdgeInsets.all(24),
              child: Text('暂无可观看回放',
                  style: ShuYoTextStyles.meta(color: colors.textMuted),
                  textAlign: TextAlign.center)),
        for (var index = 0; index < lessons.length; index++)
          ListTile(
            key: ValueKey('recording-lesson-${lessons[index].id}'),
            selected: lessons[index].id == _lesson.id,
            enabled: lessons[index].canPlay,
            selectedTileColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: .08),
            leading: RecordingStatusIcon(
                isLive: lessons[index].isLive, enabled: lessons[index].canPlay),
            title: Text(
                '第 ${lessons.length - index} 集 · ${_lessonDate(lessons[index])}',
                style: ShuYoTextStyles.bodyCompact(
                    color: lessons[index].canPlay
                        ? colors.textPrimary
                        : colors.textMuted)),
            subtitle: Text(
                [
                  lessons[index].statusLabel,
                  if (lessons[index].classroom.isNotEmpty)
                    lessons[index].classroom
                ].join(' · '),
                style: ShuYoTextStyles.meta(
                    color: lessons[index].canPlay
                        ? colors.textSecondary
                        : colors.textMuted)),
            trailing: lessons[index].id == _lesson.id && lessons[index].canPlay
                ? Text('当前',
                    style: ShuYoTextStyles.meta(
                        color: Theme.of(context).colorScheme.primary))
                : null,
            onTap: !lessons[index].canPlay || lessons[index].id == _lesson.id
                ? null
                : () => unawaited(_loadLesson(lessons[index])),
          ),
      ],
    );
    return widget.repository == null
        ? content
        : RefreshIndicator(
            onRefresh: () => _loadCatalog(forceRefresh: true),
            child: content,
          );
  }
}

String _lessonDate(VodLesson lesson) {
  final begin = lesson.beginTime;
  if (begin == null) return lesson.sectionLabel;
  final hour = begin.hour.toString().padLeft(2, '0');
  final minute = begin.minute.toString().padLeft(2, '0');
  return '${begin.month}月${begin.day}日 $hour:$minute'
      '${lesson.sectionLabel.isEmpty ? '' : ' · ${lesson.sectionLabel}'}';
}
