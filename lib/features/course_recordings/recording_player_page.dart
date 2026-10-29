import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_live_stream_proxy.dart';
import '../../data/services/vod_webrtc_session.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_course_title.dart';
import 'recording_classroom_filter.dart';
import 'recording_episode_tile.dart';
import 'recording_episode_sort_icon.dart';
import 'recording_playback_status.dart';
import 'recording_player_cache.dart';
import 'recording_player_layout.dart';
import 'recording_player_system_ui.dart';
import 'recording_seek_controller.dart';
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
  static const _playingSyncTolerance = Duration(seconds: 1);
  static const _pausedSyncTolerance = Duration(milliseconds: 250);
  static const _syncDelay = Duration(milliseconds: 800);
  static const _syncCooldown = Duration(seconds: 3);

  final _videoKey = GlobalKey<VideoState>();
  final _controlsRevision = ValueNotifier(0);
  final _systemUi = RecordingPlayerSystemUi();
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
  bool _episodesNewestFirst = true;
  final _excludedClassrooms = <String>{};
  final _episodeKeys = <int, GlobalKey>{};
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
  bool _seekCommandsRunning = false;
  int _seekSyncRevision = 0;
  Timer? _seekSyncTimer;
  Duration? _seekSyncTarget;
  final _seekAwaitingPosition = <Player>{};
  bool _syncingSecondary = false;
  Timer? _driftTimer;
  Timer? _driftCooldownTimer;
  Completer<void>? _secondarySyncCompletion;
  bool _secondarySyncPending = false;
  String _aspect = '自动';
  VodLiveProtocol _liveProtocol = VodLiveProtocol.hls;
  List<VodWebRtcSession> _rtcSessions = [];
  Future<void> _rtcSwapQueue = Future<void>.value();
  int? _rtcRequestedView;
  bool get _isWebRtc =>
      _lesson.isLive && _liveProtocol == VodLiveProtocol.webRtc;
  bool get _rtcPlaying =>
      _viewIndex < _rtcSessions.length &&
      _rtcSessions[_viewIndex].state.value == VodWebRtcState.playing;
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

  List<String> get _classrooms {
    final rooms =
        _lessons.map((lesson) => lesson.classroom.trim()).toSet().toList()
          ..sort((first, second) => first.isEmpty
              ? 1
              : second.isEmpty
                  ? -1
                  : first.compareTo(second));
    return rooms;
  }

  List<VodLesson> get _filteredLessons => _classrooms.length < 2
      ? _lessons
      : _lessons
          .where((lesson) =>
              !_excludedClassrooms.contains(lesson.classroom.trim()))
          .toList();

  void _setClassroom(String classroom, bool selected) => _publish(() {
        if (selected) {
          _excludedClassrooms.remove(classroom);
        } else {
          _excludedClassrooms.add(classroom);
        }
      });

  Widget _classroomFilter() => RecordingClassroomFilter(
        classrooms: _classrooms,
        excluded: _excludedClassrooms,
        onChanged: _setClassroom,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isMobile) _systemUi.lockPortrait();
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
        await _disposeRtc();
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
      await _pauseRtc();
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
        !(_isWebRtc ? _rtcPlaying : _player?.state.playing == true)) {
      return;
    }
    _heartbeatPending = true;
    try {
      await widget.repository?.keepLiveAlive(widget.course, _lesson);
    } on VodSessionExpiredException {
      if (mounted && revision == _loadRevision) {
        _stopLiveTimers();
        await _player?.pause();
        await _pauseRtc();
        _publish(() => _failure = _PlaybackFailure.session);
      }
    } on VodPermissionException {
      if (mounted && revision == _loadRevision) {
        _stopLiveTimers();
        await _player?.pause();
        await _pauseRtc();
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
      _resumeLive = _resumeLive ||
          _lesson.isLive &&
              (_isWebRtc ? _rtcPlaying : (_player?.state.playing ?? false));
      _stopLiveTimers();
      unawaited(_player?.pause());
      unawaited(_secondaryPlayer?.pause());
      unawaited(_pauseRtc());
    } else if (_resumeLive) {
      _resumeLive = false;
      unawaited(_loadLesson(_lesson));
    }
  }

  @override
  void dispose() {
    _loadRevision++;
    _clearDriftTimers();
    _resetSeekSynchronization();
    _catalogRevision++;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    WidgetsBinding.instance.removeObserver(this);
    _stopLiveTimers();
    unawaited(_liveProxy?.dispose());
    unawaited(_disposeRtc());
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
    _clearDriftTimers();
    _resetSeekSynchronization();
    _openingMediaRevision = null;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    _secondaryLoading = false;
    _secondaryWaitingForMain = false;
    _pendingViewIndex = null;
    await _disposeRtc();
    if (!mounted || revision != _loadRevision) return;
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
      final playback = await (lesson.isLive &&
              _liveProtocol != VodLiveProtocol.hls &&
              widget.repository != null
          ? widget.repository!.prepareLivePlaybackWithProtocol(
              course: widget.course, lesson: lesson, protocol: _liveProtocol)
          : widget.loadPlayback?.call(lesson) ??
              widget.repository!
                  .preparePlayback(course: widget.course, lesson: lesson));
      if (!mounted || revision != _loadRevision) return;
      if (playback.lessonId != lesson.id ||
          playback.teachingClassId != widget.course.teachingClassId ||
          playback.views.isEmpty ||
          playback.isLive != lesson.isLive ||
          playback.views.any((view) => _isWebRtc
              ? view.webRtcSource == null
              : !const ['http', 'https'].contains(view.url.scheme) ||
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
              webRtcSource: classroom.webRtcSource,
              displayLabel: '教室'),
        if (ppt != null)
          VodView(
              viewNumber: ppt.viewNumber,
              url: ppt.url,
              httpHeaders: ppt.httpHeaders,
              webRtcSource: ppt.webRtcSource,
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
      if (_isWebRtc) {
        await _openRtcViews(revision);
        return;
      }
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
        _failureMessage = error is VodLiveUnavailableException
            ? error.message
            : _isWebRtc && _viewIndex < _rtcSessions.length
                ? _rtcSessions[_viewIndex].error
                : null;
        _loading = false;
        _failure = switch (error) {
          VodSessionExpiredException() => _PlaybackFailure.session,
          VodPermissionException() => _PlaybackFailure.permission,
          VodNetworkException() => _PlaybackFailure.network,
          _ =>
            _isWebRtc ? _PlaybackFailure.media : _PlaybackFailure.unavailable,
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
          _syncSubscriptions.add(player.stream.position.listen((position) {
            _observeSeekPosition(created, position);
            unawaited(_alignSecondary());
          }));
          for (final stream in <Stream<dynamic>>[
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

  Future<void> _disposeRtc() async {
    final sessions = _rtcSessions;
    _rtcSessions = [];
    _rtcRequestedView = null;
    for (final session in sessions) {
      try {
        await session.dispose();
      } on Object catch (error) {
        debugPrint('ShuYoVOD WebRTC teardown failure: ${error.runtimeType}');
      }
    }
  }

  Future<void> _pauseRtc() async {
    for (final session in _rtcSessions.toList()) {
      await session.pause();
    }
  }

  Future<void> _playRtc() async {
    for (final session in _rtcSessions.toList()) {
      await session.play();
    }
  }

  Future<void> _toggleRtcPlayback() async {
    if (_rtcPlaying) {
      await _pauseRtc();
    } else {
      await _playRtc();
    }
  }

  Future<void> _openRtcViews(int revision) async {
    final playback = _playback!;
    var player = _player;
    if (player == null) {
      player = widget.playerFactory?.call() ??
          Player(configuration: const PlayerConfiguration(title: 'ShuYo 课程视频'));
      _player = player;
      _videoController = widget.videoControllerFactory?.call(player) ??
          VideoController(player);
      _hostVideoController ??= _videoController;
      final created = player;
      _errorSubscription =
          player.stream.error.listen((_) => _onPlayerError(created));
      _syncSubscriptions.add(player.stream.position.listen((position) {
        _observeSeekPosition(created, position);
        unawaited(_alignSecondary());
      }));
      for (final stream in <Stream<dynamic>>[
        player.stream.playing,
        player.stream.buffering,
        player.stream.rate
      ]) {
        _syncSubscriptions
            .add(stream.listen((_) => unawaited(_alignSecondary())));
      }
      _watchCacheRate(player);
    }
    final sessions = playback.views
        .map((view) => VodWebRtcSession(view.webRtcSource!))
        .toList(growable: false);
    _rtcSessions = sessions;
    for (var index = 0; index < sessions.length; index++) {
      final session = sessions[index];
      session.state.addListener(() {
        if (!mounted ||
            revision != _loadRevision ||
            !identical(_rtcSessions, sessions)) {
          return;
        }
        final state = session.state.value;
        _publish(() {
          if (index == _viewIndex) {
            if (state == VodWebRtcState.playing ||
                state == VodWebRtcState.paused) {
              _loading = false;
              _loadedLessonId = playback.lessonId;
            } else if (state == VodWebRtcState.failed) {
              _loading = false;
              _failure = _PlaybackFailure.media;
              _failureMessage = session.error;
            }
          } else {
            _secondaryLoading = state == VodWebRtcState.idle ||
                state == VodWebRtcState.connecting;
            _secondaryFailed = state == VodWebRtcState.failed;
          }
        });
        if ((state == VodWebRtcState.playing ||
                state == VodWebRtcState.paused) &&
            _rtcRequestedView != null) {
          _drainRtcSwap(revision);
        }
      });
    }
    _publish(() {
      _secondaryLoading = sessions.length > 1;
      _secondaryFailed = false;
    });
    await _videoController!.platform.future
        .timeout(const Duration(seconds: 20));
    if (!mounted || revision != _loadRevision) return;
    for (var index = 0; index < sessions.length; index++) {
      await sessions[index].setAudioEnabled(index == _viewIndex);
    }
    if (!mounted || revision != _loadRevision) return;
    await sessions[_viewIndex].start();
    if (!mounted || revision != _loadRevision) return;
    for (var index = 0; index < sessions.length; index++) {
      if (index != _viewIndex) {
        unawaited(sessions[index].start().catchError((Object _) {}));
      }
    }
    if (!_foreground) await _pauseRtc();
    if (!mounted || revision != _loadRevision) return;
    unawaited(_heartbeat(revision));
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(_heartbeat(revision)));
    final end = _lesson.liveEndTime ?? _lesson.endTime;
    if (end != null) {
      final remaining = end.difference(DateTime.now());
      _liveEndTimer =
          Timer(remaining.isNegative ? Duration.zero : remaining, () {
        _stopLiveTimers();
        unawaited(_pauseRtc());
        if (mounted) _publish(() => _failure = _PlaybackFailure.unavailable);
        unawaited(_loadCatalog(forceRefresh: true));
      });
    }
  }

  void _requestRtcSwap() {
    if (_rtcSessions.length < 2 || _loading) return;
    final current = _rtcRequestedView ?? _viewIndex;
    _rtcRequestedView = current == 0 ? 1 : 0;
    _drainRtcSwap(_loadRevision);
  }

  void _drainRtcSwap(int revision) {
    _rtcSwapQueue = _rtcSwapQueue.then((_) async {
      while (mounted && revision == _loadRevision) {
        final target = _rtcRequestedView;
        if (target == null) return;
        if (target == _viewIndex) {
          _rtcRequestedView = null;
          return;
        }
        final sessions = _rtcSessions;
        if (sessions.length <= target ||
            sessions[target].state.value != VodWebRtcState.playing &&
                sessions[target].state.value != VodWebRtcState.paused) {
          return;
        }
        final original = _viewIndex;
        await sessions[original].setAudioEnabled(false);
        if (!mounted || revision != _loadRevision) return;
        if (_rtcRequestedView != target) {
          await sessions[original].setAudioEnabled(true);
          continue;
        }
        await sessions[target].setAudioEnabled(true);
        if (!mounted || revision != _loadRevision) return;
        _publish(() {
          _viewIndex = target;
          _preferredView = _playback!.views[target].label;
          if (_rtcRequestedView == target) _rtcRequestedView = null;
        });
      }
    }).catchError((Object _) {
      if (mounted && revision == _loadRevision) {
        _rtcRequestedView = null;
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('切换视角失败，请重试')));
      }
    });
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

  void _requestSwap() {
    if (_isWebRtc) {
      _requestRtcSwap();
      return;
    }
    if ((_playback?.views.length ?? 0) < 2 || _loading) return;
    final current = _pendingViewIndex ?? _viewIndex;
    final next = current == 0 ? 1 : 0;
    _pendingViewIndex = next;
    if (!_swappingViews) unawaited(_selectView(next));
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
    final volume = primary.state.volume;
    var audioTransitionStarted = false;
    _swappingViews = true;
    try {
      _driftTimer?.cancel();
      _driftTimer = null;
      audioTransitionStarted = true;
      await primary.setVolume(0);
      if (!mounted ||
          revision != _loadRevision ||
          _pendingViewIndex != null && _pendingViewIndex != index) {
        if (mounted && identical(primary, _player)) {
          await primary.setVolume(volume);
        }
        return;
      }
      await secondary.setVolume(volume);
      if (!mounted ||
          revision != _loadRevision ||
          _pendingViewIndex != null && _pendingViewIndex != index) {
        if (mounted && revision == _loadRevision) await secondary.setVolume(0);
        if (mounted && identical(primary, _player)) {
          await primary.setVolume(volume);
        }
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
    } on Object {
      if (mounted && revision == _loadRevision) {
        if (audioTransitionStarted) {
          await _restoreSwapVolume(secondary, 0);
          await _restoreSwapVolume(primary, volume);
        }
        if (_pendingViewIndex == index) _pendingViewIndex = null;
        if (mounted && revision == _loadRevision) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('切换视角失败，请重试')));
        }
      }
    } finally {
      _swappingViews = false;
      final pending = _pendingViewIndex;
      if (pending == _viewIndex) {
        _pendingViewIndex = null;
      } else if (pending != null &&
          mounted &&
          revision == _loadRevision &&
          !_secondaryFailed &&
          !_secondaryLoading &&
          !_secondaryWaitingForMain &&
          _secondaryViewIndex == pending) {
        unawaited(_selectView(pending));
      }
    }
  }

  Future<void> _restoreSwapVolume(Player player, double volume) async {
    try {
      await player.setVolume(volume);
    } on Object {
      return;
    }
  }

  void _onPlayerError(Player source) {
    if (!mounted || _isWebRtc) return;
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

  void _resetSeekSynchronization() {
    _seekSyncRevision++;
    _seekSyncTimer?.cancel();
    _seekSyncTimer = null;
    _seekSyncTarget = null;
    _seekAwaitingPosition.clear();
    _seekCommandsRunning = false;
    _seekingPlayers = false;
  }

  void _finishSeekSynchronization({bool timedOut = false}) {
    final primary = _player;
    final timeline = _timelinePlayer;
    if (timedOut &&
        primary != null &&
        timeline != null &&
        !_seekAwaitingPosition.contains(primary) &&
        _seekAwaitingPosition.contains(timeline)) {
      _timelinePlayer = primary;
    }
    _resetSeekSynchronization();
    if (mounted) unawaited(_alignSecondary());
  }

  void _observeSeekPosition(Player player, Duration position) {
    final target = _seekSyncTarget;
    if (target == null || !recordingSeekPositionMatches(position, target)) {
      return;
    }
    _seekAwaitingPosition.remove(player);
    if (_seekAwaitingPosition.isEmpty && !_seekCommandsRunning) {
      _finishSeekSynchronization();
    }
  }

  Future<void> _seekPlayers(Duration position) async {
    final primary = _player;
    final secondary = _secondaryPlayer;
    if (primary == null || _lesson.isLive || _loading) return;
    _resetSeekSynchronization();
    final revision = _seekSyncRevision;
    final players = <Player>[
      primary,
      if (secondary != null &&
          _secondaryViewIndex != null &&
          !_secondaryLoading &&
          !_secondaryFailed)
        secondary,
    ];
    _seekSyncTarget = position;
    _seekAwaitingPosition.addAll(players);
    _seekingPlayers = true;
    _seekCommandsRunning = true;
    try {
      await Future.wait(players.map((player) => player.seek(position)));
    } catch (_) {
      if (revision == _seekSyncRevision) _resetSeekSynchronization();
      rethrow;
    }
    if (revision != _seekSyncRevision) return;
    _seekCommandsRunning = false;
    for (final player in players) {
      _observeSeekPosition(player, player.state.position);
    }
    if (_seekingPlayers) {
      _seekSyncTimer = Timer(recordingSeekPositionTimeout, () {
        if (revision == _seekSyncRevision) {
          _finishSeekSynchronization(timedOut: true);
        }
      });
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
    if (_fullscreenActive) return;
    _fullscreenActive = true;
    if (_isMobile) {
      _systemUi.enterFullscreen();
    } else {
      await defaultEnterNativeFullscreen();
    }
  }

  Future<void> _exitFullscreen() async {
    if (_episodePanelVisible) return;
    await _performExitFullscreen();
  }

  Future<void> _performExitFullscreen() async {
    if (!_fullscreenActive) return;
    _fullscreenActive = false;
    if (_isMobile) {
      _systemUi.exitFullscreen();
    } else {
      await defaultExitNativeFullscreen();
    }
  }

  bool get _isMobile =>
      !kIsWeb &&
      const [TargetPlatform.android, TargetPlatform.iOS]
          .contains(defaultTargetPlatform);

  Future<void> _restoreOrientation() async {
    if (_isMobile) {
      _fullscreenActive = false;
      _systemUi.release();
    } else if (_fullscreenActive) {
      await _performExitFullscreen();
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
    if (_isWebRtc) {
      if (value && _secondaryFailed && _rtcSessions.length > 1) {
        final secondary = _rtcSessions[_viewIndex == 0 ? 1 : 0];
        unawaited(secondary.start().catchError((Object _) {}));
      }
      return;
    }
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
          _syncSubscriptions.add(secondary.stream.position.listen((position) {
            _observeSeekPosition(created, position);
            unawaited(_alignSecondary());
          }));
          for (final stream in <Stream<dynamic>>[
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

  void _clearDriftTimers() {
    _driftTimer?.cancel();
    _driftTimer = null;
    _driftCooldownTimer?.cancel();
    _driftCooldownTimer = null;
  }

  Future<void> _alignSecondary({bool correctDrift = false}) async {
    if (_isWebRtc) return;
    if (_syncingSecondary) {
      _secondarySyncPending = true;
      await _secondarySyncCompletion?.future;
      if (correctDrift) {
        await _alignSecondary(correctDrift: correctDrift);
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
        _swappingViews ||
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
      final playing = timeline.state.playing && follower.state.playing;
      final tolerance = playing ? _playingSyncTolerance : _pausedSyncTolerance;
      final drift = (timeline.state.position - follower.state.position).abs();
      if (!_lesson.isLive &&
          !timeline.state.buffering &&
          !follower.state.buffering &&
          drift > tolerance) {
        if (!playing || correctDrift && _driftCooldownTimer == null) {
          _driftTimer?.cancel();
          _driftTimer = null;
          await follower.seek(timeline.state.position);
          if (!stillCurrent()) return;
          if (playing) {
            _driftCooldownTimer = Timer(_syncCooldown, () {
              _driftCooldownTimer = null;
              if (mounted) unawaited(_alignSecondary());
            });
          }
        } else if (_driftTimer == null && _driftCooldownTimer == null) {
          _driftTimer = Timer(_syncDelay, () {
            _driftTimer = null;
            if (mounted) unawaited(_alignSecondary(correctDrift: true));
          });
        }
      } else {
        _driftTimer?.cancel();
        _driftTimer = null;
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
      if (pending != null && !_swappingViews) {
        unawaited(_selectView(pending));
      }
    }
  }

  Widget _secondaryView() => ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        if (_isWebRtc && _rtcSessions.length > 1)
          RTCVideoView(_rtcSessions[_viewIndex == 0 ? 1 : 0].renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
        else if (!_isWebRtc && _secondaryController != null)
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
          top: false,
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
                              onTemporaryRate: _setTemporaryRate,
                              primaryView: _isWebRtc && _rtcSessions.isNotEmpty
                                  ? RTCVideoView(
                                      _rtcSessions[_viewIndex].renderer,
                                      objectFit:
                                          _aspect == '裁剪' || _aspect == '填充'
                                              ? RTCVideoViewObjectFit
                                                  .RTCVideoViewObjectFitCover
                                              : RTCVideoViewObjectFit
                                                  .RTCVideoViewObjectFitContain)
                                  : identical(_videoController,
                                          _hostVideoController)
                                      ? null
                                      : RecordingSecondaryVideo(
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
                              title: widget.course.name,
                              onBack: () => Navigator.of(context).maybePop(),
                              onEpisodePanelVisibilityChanged: (visible) =>
                                  _episodePanelVisible = visible,
                              lessons: _lessons,
                              episodeLessons: _filteredLessons,
                              episodeNewestFirst: _episodesNewestFirst,
                              onEpisodeOrderChanged: (value) =>
                                  _publish(() => _episodesNewestFirst = value),
                              onClearClassroomFilter: () =>
                                  _publish(_excludedClassrooms.clear),
                              selectedLessonId: _lesson.id,
                              selectedLesson: _lesson.id > 0 ? _lesson : null,
                              onLessonSelected: (lesson) =>
                                  unawaited(_loadLesson(lesson)),
                              dualEnabled: _dualEnabled,
                              onDualChanged: kIsWeb ? null : _setDualEnabled,
                              secondaryView: _secondaryView(),
                              secondaryLabel: (_playback?.views.length ?? 0) > 1
                                  ? _playback!
                                      .views[_viewIndex == 0 ? 1 : 0].label
                                  : '',
                              onSwapViews: _requestSwap,
                              aspect: _aspect,
                              onAspectChanged: _changeAspect,
                              loading: _loading,
                              isLive: _lesson.isLive,
                              livePlaying: _isWebRtc ? _rtcPlaying : null,
                              onLiveTogglePlayback: _isWebRtc
                                  ? () => unawaited(_toggleRtcPlayback())
                                  : null,
                              liveProtocol: _liveProtocol,
                              onLiveProtocolChanged: widget.repository == null
                                  ? null
                                  : (protocol) {
                                      if (protocol == _liveProtocol) return;
                                      _publish(() => _liveProtocol = protocol);
                                      unawaited(_loadLesson(_lesson));
                                    },
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
                final portrait =
                    MediaQuery.orientationOf(context) == Orientation.portrait &&
                        constraints.maxWidth < 1000;
                final list = _lessonList(colors, nested: portrait);
                final topInset = MediaQuery.viewPaddingOf(context).top;
                if (constraints.maxWidth >= 1000) {
                  return Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: ListView(
                                children: [video, _lessonHeading(colors)]),
                          ),
                          SizedBox(width: 360, child: list),
                        ],
                      ),
                    ),
                  );
                }
                final videoHeight = math.min(constraints.maxWidth * 9 / 16,
                    math.max(100.0, (constraints.maxHeight - topInset) * .6));
                if (MediaQuery.orientationOf(context) == Orientation.portrait) {
                  return RecordingPlayerLayout(
                    video: video,
                    body: list,
                    expandedHeight: videoHeight,
                    topInset: topInset,
                    player: _player,
                    playingOverride: _isWebRtc ? _rtcPlaying : null,
                    canResume:
                        !_loading && _failure == null && _playback != null,
                    onResume: () async {
                      if (_isWebRtc) {
                        await _playRtc();
                        return;
                      }
                      if (_player?.state.completed ?? false) {
                        await _seekPlayers(Duration.zero);
                      }
                      await _player?.play();
                    },
                    onBack: () => Navigator.of(context).maybePop(),
                  );
                }
                return Padding(
                  padding: EdgeInsets.only(top: topInset),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: Column(children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.max(
                              100.0, (constraints.maxHeight - topInset) * .6),
                        ),
                        child: AspectRatio(aspectRatio: 16 / 9, child: video),
                      ),
                      Expanded(child: list),
                    ]),
                  ),
                );
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
    return Padding(
      key: const ValueKey('recording-course-banner'),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RecordingCourseTitle(course: widget.course, large: true),
        if (_playback?.description.isNotEmpty ?? false) ...[
          const SizedBox(height: 10),
          Text(_playback!.description,
              style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary)),
        ],
      ]),
    );
  }

  Widget _lessonList(ShuYoColors colors, {required bool nested}) {
    final chronological = _lessons;
    final filtered = _filteredLessons;
    final lessons = _episodesNewestFirst
        ? filtered
        : filtered.reversed.toList(growable: false);
    final episodeNumbers = {
      for (var index = 0; index < chronological.length; index++)
        chronological[index].id: chronological.length - index,
    };
    final content = CustomScrollView(
      key: const ValueKey('course-player-episodes'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (nested)
          SliverLayoutBuilder(
              builder: (context, constraints) => SliverOverlapInjector(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                      context))),
        SliverToBoxAdapter(child: _lessonHeading(colors)),
        if (_catalogLoading)
          const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _EpisodeHeader(
            colors: colors,
            classroomFilter: _classrooms.isEmpty ? null : _classroomFilter(),
            newestFirst: _episodesNewestFirst,
            hasLessons: lessons.isNotEmpty,
            hasCurrent: chronological.any((lesson) => lesson.id == _lesson.id),
            onFirst: () => _scrollToEpisode(lessons.first.id, alignment: .5),
            onLast: () => _scrollToEpisode(lessons.last.id, alignment: 1),
            onCurrent: () => _scrollToEpisode(_lesson.id, alignment: .5),
            onReverse: () =>
                _publish(() => _episodesNewestFirst = !_episodesNewestFirst),
          ),
        ),
        if (lessons.isEmpty && !_catalogLoading)
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(chronological.isEmpty ? '暂无可观看回放' : '没有符合教室筛选的课次',
                      style: ShuYoTextStyles.meta(color: colors.textMuted),
                      textAlign: TextAlign.center))),
        SliverToBoxAdapter(
            child: Column(children: [
          for (final lesson in lessons)
            KeyedSubtree(
                key: _episodeKeys.putIfAbsent(lesson.id, GlobalKey.new),
                child: RecordingEpisodeTile(
                  tileKey: ValueKey('recording-lesson-${lesson.id}'),
                  lesson: lesson,
                  number: episodeNumbers[lesson.id]!,
                  selected: lesson.id == _lesson.id,
                  onTap: !lesson.canPlay || lesson.id == _lesson.id
                      ? null
                      : () => unawaited(_loadLesson(lesson)),
                )),
          SizedBox(height: 24 + MediaQuery.viewPaddingOf(context).bottom),
        ])),
      ],
    );
    return widget.repository == null
        ? content
        : RefreshIndicator(
            onRefresh: () => _loadCatalog(forceRefresh: true),
            child: content,
          );
  }

  void _scrollToEpisode(int id, {required double alignment}) {
    final target = _episodeKeys[id]?.currentContext;
    if (target == null) {
      if (_lessons.any((lesson) => lesson.id == id) &&
          !_filteredLessons.any((lesson) => lesson.id == id)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: const Text('当前课次不在教室筛选结果中'),
          action: SnackBarAction(
              label: '清除筛选',
              onPressed: () => _publish(_excludedClassrooms.clear)),
        ));
      }
      return;
    }
    unawaited(Scrollable.ensureVisible(target,
        alignment: alignment,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeOut));
  }

  Future<void> _setTemporaryRate(double rate) async {
    final primary = _player;
    final secondary = _secondaryPlayer;
    await Future.wait([
      if (primary != null) primary.setRate(rate),
      if (secondary != null && !identical(primary, secondary))
        secondary.setRate(rate),
    ]);
  }
}

class _EpisodeHeader extends SliverPersistentHeaderDelegate {
  _EpisodeHeader(
      {required this.colors,
      required this.classroomFilter,
      required this.newestFirst,
      required this.hasLessons,
      required this.hasCurrent,
      required this.onFirst,
      required this.onLast,
      required this.onCurrent,
      required this.onReverse});

  final ShuYoColors colors;
  final Widget? classroomFilter;
  final bool newestFirst;
  final bool hasLessons;
  final bool hasCurrent;
  final VoidCallback onFirst;
  final VoidCallback onLast;
  final VoidCallback onCurrent;
  final VoidCallback onReverse;

  @override
  double get minExtent => classroomFilter == null ? 45 : 95;
  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Material(
        key: const ValueKey('recording-episode-header'),
        color: Theme.of(context).colorScheme.surface,
        elevation: overlapsContent ? 2 : 0,
        child: SizedBox.expand(
            child: Column(children: [
          if (classroomFilter != null) classroomFilter!,
          SizedBox(
              height: 45,
              child: Row(children: [
                const SizedBox(width: 14),
                Text('剧集',
                    style: TextStyle(fontSize: 16, color: colors.textPrimary)),
                _button(
                    tooltip: '跳至顶部',
                    icon: const Icon(Icons.vertical_align_top),
                    onPressed: hasLessons ? onFirst : null),
                _button(
                    tooltip: '跳至底部',
                    icon: const Icon(Icons.vertical_align_bottom),
                    onPressed: hasLessons ? onLast : null),
                _button(
                    tooltip: '跳至当前',
                    icon: const Icon(Icons.my_location),
                    onPressed: hasCurrent ? onCurrent : null),
                const Spacer(),
                _button(
                    tooltip: newestFirst ? '切换为正序' : '切换为倒序',
                    icon: RecordingEpisodeSortIcon(descending: newestFirst),
                    onPressed: hasLessons ? onReverse : null),
                const SizedBox(width: 14),
              ])),
        ])),
      );

  Widget _button(
          {required String tooltip,
          required Widget icon,
          required VoidCallback? onPressed}) =>
      SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          tooltip: tooltip,
          icon: icon,
          onPressed: onPressed,
          style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              iconSize: 22,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
      );

  @override
  bool shouldRebuild(_EpisodeHeader oldDelegate) => true;
}
