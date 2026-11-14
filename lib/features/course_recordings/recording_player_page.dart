import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../core/background_work_gate.dart';
import '../../data/models/vod_ppt.dart';
import '../../data/repositories/vod_repository.dart';
import '../../data/services/vod_api_client.dart';
import '../../data/services/vod_live_stream_proxy.dart';
import '../../data/services/vod_webrtc_session.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_course_title.dart';
import 'recording_course_overview.dart';
import 'recording_classroom_filter.dart';
import 'recording_playback_info.dart';
import 'recording_player_preferences.dart';
import 'recording_player_menu.dart';
import 'recording_episode_tile.dart';
import 'recording_lesson_selection.dart';
import 'recording_episode_sort_icon.dart';
import 'recording_playback_status.dart';
import 'recording_notes_panel.dart';
import 'recording_notes_controller.dart';
import 'recording_episode_catalog.dart';
import 'recording_route_work_gate.dart';
import 'recording_transport_coordinator.dart';
import 'recording_player_cache.dart';
import 'recording_player_layout.dart';
import 'recording_player_tabs.dart';
import 'recording_player_system_ui.dart';
import 'recording_seek_controller.dart';
import 'recording_secondary_video.dart';
import 'recording_video_controls.dart';

export 'recording_video_controls.dart';

/// A route for account-authorized live lessons and recordings.
///
/// Sources are refreshed from the server for every lesson change and retry.
/// Recordings can fall back to account-scoped local links when that refresh
/// fails; live sources remain temporary. URLs never become widget keys.
class RecordingPlayerPage extends StatefulWidget {
  const RecordingPlayerPage({
    super.key,
    required this.course,
    this.term,
    this.lessons = const [],
    this.initialLesson,
    this.loadCourseCatalog = true,
    this.loadPreviewCatalog = false,
    this.skipInitialCatalogLoad = false,
    this.initialPreviewCatalog,
    this.loadPlayback,
    this.loadNotes,
    this.repository,
    this.onSessionExpired,
    this.onWebVpnSessionExpired,
    this.playerFactory,
    this.videoControllerFactory,
    this.liveProxyFactory,
    this.webRtcSessionFactory,
  });

  final VodCourse course;
  final VodTerm? term;
  final List<VodLesson> lessons;
  final VodLesson? initialLesson;

  /// Whether to load the regular course catalog.
  final bool loadCourseCatalog;

  /// Load a preview catalog for a lesson opened from search.
  final bool loadPreviewCatalog;

  /// Use the supplied catalog on entry; explicit refreshes are still allowed.
  final bool skipInitialCatalogLoad;

  /// A search preview already in progress, shared with the search page.
  final Future<List<VodLesson>>? initialPreviewCatalog;
  final Future<VodPlayback> Function(VodLesson)? loadPlayback;
  final Future<List<VodPptSlide>> Function(int courseId)? loadNotes;
  final VodRepository? repository;
  final Future<bool> Function()? onSessionExpired;
  final Future<bool> Function()? onWebVpnSessionExpired;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final VideoController Function(Player)? videoControllerFactory;
  @visibleForTesting
  final VodLiveStreamProxy Function(VodRepository)? liveProxyFactory;
  @visibleForTesting
  final VodWebRtcSession Function(VodWebRtcSource)? webRtcSessionFactory;

  @override
  State<RecordingPlayerPage> createState() => _RecordingPlayerPageState();
}

enum _PlaybackFailure {
  session,
  webVpnSession,
  permission,
  network,
  unavailable,
  media
}

class _RecordingPlayerPageState extends State<RecordingPlayerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool get _shouldLoadCatalog =>
      widget.loadCourseCatalog || widget.loadPreviewCatalog;
  VodTerm? get _courseTerm =>
      widget.term?.id == widget.course.termId ? widget.term : null;

  String? get _compactTermLabel {
    final term = _courseTerm;
    if (term == null) return null;
    final year = term.academicYear.isEmpty
        ? ''
        : term.academicYearLabel.replaceFirst('学年', '');
    return [
      if (year.isNotEmpty) year,
      term.seasonLabel.replaceFirst('学期', ''),
    ].join(' ');
  }

  final _videoKey = GlobalKey<VideoState>();
  final _entryWork = RecordingRouteWorkGate();
  bool _entryContentReady = true;
  bool _entryContentScheduled = false;
  final _controlsRevision = ValueNotifier(0);
  late final TabController _tabController;
  late final RecordingNotesController _notesController;
  final _episodeCatalogCache = RecordingEpisodeCatalogCache();
  final _lessonListCache = <bool, (Object, Widget)>{};
  (Object, Widget)? _portraitBodyCache;
  PreferredSizeWidget? _portraitTabBar;
  RecordingPlayerPreferences _playerPreferences =
      const RecordingPlayerPreferences();
  Future<void> _preferencesQueue = Future<void>.value();
  late final Future<void> _playerPreferencesReady;
  int _preferencesRevision = 0;
  bool _collapsedMenuOpen = false;
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
  bool _resumePlayback = false;
  bool _lifecycleResumePending = false;
  int? _resumeRecordingRevision;
  Future<void> _lifecycleQueue = Future<void>.value();
  bool _heartbeatPending = false;
  bool _catalogLoading = false;
  bool _catalogSyncing = false;
  bool _episodesNewestFirst = true;
  String? _selectedClassroom;
  final _episodeKeys = <int, GlobalKey>{};
  final _episodeHeadingKey = GlobalKey();
  final _landscapeEpisodeKeys = <int, GlobalKey>{};
  final _landscapeEpisodeHeadingKey = GlobalKey();
  Size? _portraitViewport;
  MediaQueryData? _portraitMediaQuery;
  int _episodeNavigationRevision = 0;
  int _catalogRevision = 0;
  VodPlayback? _playback;
  int _viewIndex = 0;
  int? _loadedLessonId;
  int _loadRevision = 0;
  int? _openingMediaRevision;
  Future<void> _mediaQueue = Future<void>.value();
  final _transport = RecordingTransportCoordinator();
  bool _loading = true;
  bool _recovering = false;
  bool _fullscreenActive = false;
  bool _episodePanelVisible = false;
  bool get _dualEnabled => _playerPreferences.secondaryView;
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
  bool _routingViewAudio = false;
  int _viewAudioRevision = 0;
  double _viewVolume = 100;
  bool _viewVolumeInitialized = false;
  Future<void> _viewAudioQueue = Future<void>.value();
  bool _seekingPlayers = false;
  bool _seekCommandsRunning = false;
  int _seekSyncRevision = 0;
  Timer? _seekSyncTimer;
  Duration? _seekSyncTarget;
  final _seekAwaitingPosition = <Player>{};
  bool _syncingSecondary = false;
  Completer<void>? _secondarySyncCompletion;
  bool _secondarySyncPending = false;
  bool _hasObservedLiveSecondaryPosition = false;
  bool _postSeekVerifyWindow = false;
  Timer? _postSeekCooldownTimer;
  Timer? _liveSyncWatchdogTimer;
  DateTime? _lastLiveRecoverAt;
  bool _liveSyncMismatchPending = false;
  String _aspect = '自动';
  VodLiveProtocol _liveProtocol = VodLiveProtocol.hls;
  bool _liveProtocolSelected = false;
  List<VodWebRtcSession> _rtcSessions = [];
  StreamSubscription<double>? _rtcVolumeSubscription;
  Future<void> _rtcSwapQueue = Future<void>.value();
  int? _rtcRequestedView;
  bool get _isWebRtc =>
      _lesson.isLive && _liveProtocol == VodLiveProtocol.webRtc;
  bool get _rtcPlaying =>
      _viewIndex < _rtcSessions.length &&
      _rtcSessions[_viewIndex].state.value == VodWebRtcState.playing;

  Widget? _webRtcResolutionLabel() {
    if (!_isWebRtc || _viewIndex >= _rtcSessions.length) return null;
    final renderer = _rtcSessions[_viewIndex].renderer;
    return ValueListenableBuilder(
      valueListenable: renderer,
      builder: (context, value, child) => RecordingVideoResolutionLabel(
        width: renderer.videoWidth,
        height: renderer.videoHeight,
      ),
    );
  }

  Future<List<RecordingPlaybackInfoEntry>> _readPlaybackInformation() async {
    final view = _playback?.views.elementAtOrNull(_viewIndex);
    if (_isWebRtc && _viewIndex < _rtcSessions.length) {
      final session = _rtcSessions[_viewIndex];
      final details = await session.playbackInformation();
      return [
        (
          title: 'Resolution',
          value: session.renderer.videoWidth > 0 &&
                  session.renderer.videoHeight > 0
              ? '${session.renderer.videoWidth}x${session.renderer.videoHeight}'
              : '不可用'
        ),
        (title: 'VideoParams', value: details['VideoParams'] ?? '不可用'),
        (title: 'AudioParams', value: details['AudioParams'] ?? '不可用'),
        (title: 'Media', value: view?.url.toString() ?? '不可用'),
        (title: 'AudioTrack', value: details['AudioTrack'] ?? '不可用'),
        (title: 'VideoTrack', value: details['VideoTrack'] ?? '不可用'),
        (title: 'rate', value: '1.0'),
        (title: 'Volume', value: _player?.state.volume.toString() ?? '不可用'),
        (title: 'hwdec', value: '不可用'),
      ];
    }
    final player = _player;
    if (player == null) {
      return const [(title: '状态', value: '播放器尚未就绪')];
    }
    return readRecordingPlaybackInfo(player, view: view);
  }

  Future<void> _openCollapsedMenu() async {
    if (_collapsedMenuOpen) return;
    _collapsedMenuOpen = true;
    try {
      await showRecordingPlayerMenu(
        context: context,
        fullscreen: false,
        preferences: _playerPreferences,
        onPreferencesChanged: _setPlayerPreferences,
        secondaryAvailable: (_playback?.views.length ?? 0) > 1 && !kIsWeb,
        views: _playback?.views ?? const [],
        informationLoader: _readPlaybackInformation,
      );
    } finally {
      _collapsedMenuOpen = false;
    }
  }

  Future<void> _loadPlayerPreferences() async {
    final revision = _preferencesRevision;
    final preferences = await RecordingPlayerPreferences.load();
    if (!mounted || revision != _preferencesRevision) return;
    _publish(() {
      _playerPreferences = preferences;
      if (!_liveProtocolSelected) {
        _liveProtocol = preferences.defaultLiveProtocol;
      }
    });
    if (preferences.secondaryView) _warmSecondaryWhenEnabled(true);
  }

  void _setPlayerPreferences(RecordingPlayerPreferences preferences) {
    final changed = preferences.secondaryView != _dualEnabled;
    _preferencesRevision++;
    _publish(() => _playerPreferences = preferences);
    _preferencesQueue = _preferencesQueue
        .then((_) => preferences.save())
        .catchError((Object _) {});
    if (changed) _warmSecondaryWhenEnabled(preferences.secondaryView);
  }

  String _preferredView = '教室';
  _PlaybackFailure? _failure;
  String? _failureMessage;

  RecordingEpisodeCatalog get _episodeCatalog => _episodeCatalogCache.resolve(
        lessons: _catalog,
        teachingClassId: widget.course.teachingClassId,
      );

  List<VodLesson> get _lessons => _episodeCatalog.lessons;

  List<String> get _classrooms => _episodeCatalog.classrooms;

  VodLesson get _catalogSelection => _episodeCatalog.selectionFor(_lesson);

  String? get _activeClassroom => _episodeCatalog.activeClassroom(
        selected: _selectedClassroom,
        current: _lesson,
      );

  RecordingClassroomEpisodes get _classroomEpisodes =>
      _episodeCatalog.classroom(_activeClassroom);

  List<VodLesson> get _filteredLessons => _classroomEpisodes.newestFirst;

  void _setClassroom(String classroom) {
    if (classroom == _activeClassroom) return;
    _publish(() => _selectedClassroom = classroom);
  }

  void _showCurrentClassroom() =>
      _publish(() => _selectedClassroom = _catalogSelection.classroom.trim());

  Widget _classroomFilter() => RecordingClassroomFilter(
        classrooms: _classrooms,
        selected: _activeClassroom,
        onChanged: _setClassroom,
      );

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _notesController = RecordingNotesController(
      teachingClassId: widget.course.teachingClassId,
      loader: widget.loadNotes != null || widget.repository != null
          ? (lessonId, {required forceRefresh}) =>
              widget.loadNotes?.call(lessonId) ??
              widget.repository!
                  .loadPptSlides(lessonId, forceRefresh: forceRefresh)
          : null,
    );
    WidgetsBinding.instance.addObserver(this);
    _playerPreferencesReady = _loadPlayerPreferences();
    if (_isMobile) _systemUi.lockPortrait();
    var initial = widget.initialLesson ?? widget.course.liveLesson;
    if ((widget.skipInitialCatalogLoad ||
            initial != null && recordingLessonIsGenerating(initial)) &&
        (initial == null ||
            !recordingLessonCanSelect(initial) ||
            initial.id <= 0 ||
            initial.teachingClassId != widget.course.teachingClassId)) {
      initial = preferredRecordingLesson(_lessons);
    }
    if (initial != null &&
        recordingLessonCanSelect(initial) &&
        initial.id > 0 &&
        initial.teachingClassId == widget.course.teachingClassId) {
      final selected = initial;
      _lesson = selected;
      if (!_catalog.any((lesson) =>
          lesson.id == selected.id && lesson.isLive == selected.isLive)) {
        _catalog = [selected, ..._catalog];
      }
      unawaited(_loadLesson(selected));
      if (widget.repository != null &&
          _shouldLoadCatalog &&
          !widget.skipInitialCatalogLoad) {
        unawaited(_loadCatalog(initialPreview: widget.initialPreviewCatalog));
      } else if (widget.skipInitialCatalogLoad &&
          widget.repository != null &&
          _shouldLoadCatalog) {
        // The caller already handed over its cached catalog, so the first frame
        // paints instantly. Reconcile with the server right after so the page
        // never stays on stale lessons now that there is no pull gesture.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadCatalog(background: true));
        });
      }
    } else if (widget.skipInitialCatalogLoad ||
        widget.repository == null && !_lessons.any(recordingLessonCanSelect)) {
      _loading = false;
    } else {
      unawaited(widget.repository == null || !_shouldLoadCatalog
          ? _loadLesson(_lesson)
          : _loadCatalog());
    }
  }

  Future<void> _loadCatalog(
      {bool forceRefresh = false,
      bool background = false,
      Future<List<VodLesson>>? initialPreview}) async {
    final repository = widget.repository;
    if (repository == null || !_shouldLoadCatalog) return;
    // A silent background sync never blocks an explicit load; an explicit load
    // always supersedes one that is still in flight.
    if (background ? _catalogSyncing : _catalogLoading) return;
    final revision = ++_catalogRevision;
    _catalogSyncing = background;
    _publish(() {
      if (!background) _catalogLoading = true;
    });
    try {
      final searchSeeds = <int, VodLesson>{
        for (final lesson in widget.lessons) lesson.id: lesson,
        for (final lesson in _catalog) lesson.id: lesson,
        if (_lesson.id > 0) _lesson.id: _catalogSelection,
      }.values.toList(growable: false);
      final lessons = widget.loadPreviewCatalog
          ? initialPreview != null
              ? await initialPreview
              : await repository.loadAndWarmSearchLessons(
                  widget.course, searchSeeds, forceRefresh: forceRefresh)
          : await repository.loadCourseLessons(widget.course,
              forceRefresh: forceRefresh);
      if (!mounted || revision != _catalogRevision) return;
      // An empty response must not erase a catalog that is currently playing;
      // treat it as "nothing newer" so the open stream keeps its episode list.
      if (lessons.isEmpty && _catalog.isNotEmpty) {
        _catalogSyncing = false;
        if (_catalogLoading) _publish(() => _catalogLoading = false);
        return;
      }
      if (initialPreview != null) {
        final recordings = lessons
            .where((lesson) => !lesson.isLive && !lesson.isGenerating)
            .toList(growable: false);
        if (recordings.isNotEmpty) {
          unawaited(repository.warmCourseRecordings(widget.course, recordings));
        }
      }
      _publish(() {
        if (widget.loadPreviewCatalog) {
          // Keep search results and the current selection even when the
          // preview omits them. A response must never switch playback.
          _catalog = VodRepository.mergeSearchLessons(
            widget.course,
            searchSeeds,
            [
              for (final lesson in widget.lessons)
                if (!lesson.isLive) lesson,
              if (_lesson.id > 0 && !_lesson.isLive) _catalogSelection,
              ...lessons,
            ],
          );
        } else {
          final keepCurrent = recordingLessonCanSelect(_lesson) &&
              !lessons.any((lesson) =>
                  lesson.id == _lesson.id && lesson.isLive == _lesson.isLive);
          _catalog = (_loading || background) && keepCurrent
              ? [_lesson, ...lessons]
              : lessons;
        }
        _catalogLoading = false;
      });
      // Preview refreshes must not interrupt an existing playback. A course
      // opened without an initial lesson still needs its first selection.
      if (widget.loadPreviewCatalog && _validLesson(_lesson)) return;
      final ordered = _lessons;
      final kept = ordered
          .where((lesson) =>
              lesson.id == _lesson.id && lesson.isLive == _lesson.isLive)
          .firstOrNull;
      if (kept != null && recordingLessonCanSelect(kept)) {
        // Adopt refreshed metadata (live cutoff, availability) in place. The
        // running stream is never reopened by a refresh.
        final cutoffChanged = kept.liveEndTime != _lesson.liveEndTime;
        if (!identical(kept, _lesson)) _publish(() => _lesson = kept);
        if (kept.isLive && cutoffChanged) _startLiveTimers(_loadRevision);
        if (!_loading && (_playback == null || _failure != null)) {
          await _loadLesson(kept);
        }
        return;
      }
      final selected = preferredRecordingLesson(ordered,
          currentId: _lesson.id, currentIsLive: _lesson.isLive);
      if (background && !_loading && _playback != null) {
        // A background reconciliation only refreshes the list; it must never
        // stop or replace a stream the user is already watching.
        return;
      }
      if (selected != null) {
        await _loadLesson(selected);
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
      if (background) {
        // The list is already on screen from the caller; a failed silent
        // reconciliation keeps playback and the progress bar untouched.
        _catalogSyncing = false;
        return;
      }
      if (widget.loadPreviewCatalog &&
              _validLesson(_lesson) &&
              error is! VodWebVpnSessionExpiredException ||
          ((_playback != null ||
                  _loading && recordingLessonCanSelect(_lesson)) &&
              error is! VodSessionExpiredException &&
              (error is! VodPermissionException || !_lesson.isLive))) {
        _publish(() => _catalogLoading = false);
        if (error is! VodPermissionException) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('选集刷新失败，请稍后重试')));
        }
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
          VodWebVpnSessionExpiredException() => _PlaybackFailure.webVpnSession,
          VodSessionExpiredException() => _PlaybackFailure.session,
          VodPermissionException() => _PlaybackFailure.permission,
          VodNetworkException() => _PlaybackFailure.network,
          _ => _PlaybackFailure.unavailable,
        };
      });
    } finally {
      if (_catalogSyncing) _catalogSyncing = false;
      if (mounted && revision == _catalogRevision && _catalogLoading) {
        _publish(() => _catalogLoading = false);
      }
    }
  }

  void _stopLiveTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _liveEndTimer?.cancel();
    _liveEndTimer = null;
    _liveSyncWatchdogTimer?.cancel();
    _liveSyncWatchdogTimer = null;
  }

  void _startLiveTimers(int revision) {
    _stopLiveTimers();
    final playback = _playback;
    if (!_foreground ||
        !_lesson.isLive ||
        playback == null ||
        _failure != null ||
        revision != _loadRevision) {
      return;
    }
    unawaited(_heartbeat(revision));
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(_heartbeat(revision)));
    unawaited(_checkRtcSecondarySync());
    // Periodic check for WebRTC or stalled secondary live decoders; never
    // modifies position on recordings.
    _liveSyncWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_foreground || revision != _loadRevision) return;
      if (_isWebRtc) {
        unawaited(_checkRtcSecondarySync());
      } else {
        unawaited(_alignSecondary());
      }
    });
    // A catalog refresh can extend or shorten the broadcast; prefer the
    // freshest lesson metadata over the cutoff captured when it was opened.
    final end = _lesson.liveEndTime ?? playback.liveEndTime ?? _lesson.endTime;
    if (end == null) return;
    final remaining = end.difference(DateTime.now());
    _liveEndTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!mounted || revision != _loadRevision) return;
      _stopLiveTimers();
      unawaited(_player?.pause());
      unawaited(_secondaryPlayer?.pause());
      unawaited(_pauseRtc());
      _publish(() => _failure = _PlaybackFailure.unavailable);
      unawaited(_loadCatalog(forceRefresh: true));
    });
  }

  Future<void> _heartbeat(int revision) async {
    if (!_foreground ||
        revision != _loadRevision ||
        _heartbeatPending ||
        !(_isWebRtc ? _rtcPlaying : _player?.state.playing == true)) {
      return;
    }
    if (_isWebRtc) {
      unawaited(_checkRtcSecondarySync());
    } else {
      unawaited(_alignSecondary());
    }
    _heartbeatPending = true;
    try {
      await widget.repository?.keepLiveAlive(widget.course, _lesson);
    } on VodSessionExpiredException catch (error) {
      if (mounted && revision == _loadRevision) {
        _stopLiveTimers();
        await _player?.pause();
        await _pauseRtc();
        _publish(() => _failure = error is VodWebVpnSessionExpiredException
            ? _PlaybackFailure.webVpnSession
            : _PlaybackFailure.session);
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
    // Losing window focus (notification shade, system dialogs, split screen)
    // does not mean the video is hidden. Only suspend on a real background
    // transition, and do not resume on the intermediate hidden -> inactive.
    if (state == AppLifecycleState.inactive) return;
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    if (!foreground) {
      _resumePlayback = _failure == null &&
          (_lifecycleResumePending ||
              _loading ||
              (_isWebRtc
                  ? _rtcPlaying
                  : ((_timelinePlayer ?? _player)?.state.playing ?? false)));
      _foreground = false;
      _stopLiveTimers();
      final players = [_player, _secondaryPlayer].whereType<Player>().toList();
      final sessions = _rtcSessions.toList();
      final revision = _loadRevision;
      _enqueueLifecycle(() async {
        if (revision != _loadRevision) return;
        await Future.wait([
          for (final player in players) player.pause(),
          for (final session in sessions) session.pause(),
        ]);
      });
      return;
    }
    _foreground = true;
    final resume = _resumePlayback;
    _resumePlayback = false;
    if (!resume) {
      // A manually paused live stream stays paused, but its later manual play
      // still needs keepalives and the authoritative stream expiry timer.
      _startLiveTimers(_loadRevision);
      return;
    }
    _lifecycleResumePending = true;
    final revision = _loadRevision;
    final lesson = _lesson;
    if (!lesson.isLive) _resumeRecordingRevision = revision;
    _enqueueLifecycle(() async {
      if (!mounted ||
          !_foreground ||
          revision != _loadRevision ||
          _failure != null) {
        return;
      }
      if (lesson.isLive) {
        // Source loading has its own transport queue. Do not hold lifecycle
        // commands behind a network request or an outstanding native open.
        unawaited(_loadLesson(lesson));
      } else if (!_loading) {
        await (_timelinePlayer ?? _player)?.play();
        if (!mounted || !_foreground || revision != _loadRevision) return;
        _resumeRecordingRevision = null;
        _lifecycleResumePending = false;
        await _alignSecondary(forcePositionCheck: true);
      }
    });
  }

  void _enqueueLifecycle(Future<void> Function() action) {
    // Serialize pause/resume so a late native pause cannot undo a quick return.
    _lifecycleQueue = _lifecycleQueue.then((_) async {
      if (mounted) await action();
    }).catchError((Object error) {
      debugPrint('ShuYoVOD lifecycle update failed: ${error.runtimeType}');
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    _entryWork.attach(animation);
    // A newly pushed route can briefly expose the completed placeholder proxy
    // before its real forward animation is attached in this frame.
    if (!_entryContentScheduled &&
        animation != null &&
        (animation.status != AnimationStatus.completed ||
            !route!.isFirst && route.transitionDuration > Duration.zero)) {
      _entryContentReady = false;
      _entryContentScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !await _entryWork.ready || !mounted) return;
        setState(() {
          _entryContentReady = true;
          _portraitBodyCache = null;
          _lessonListCache.clear();
        });
      });
    }
  }

  @override
  void dispose() {
    _entryWork.dispose();
    _episodeNavigationRevision++;
    _loadRevision++;
    _notesController.dispose();
    _resetSeekSynchronization();
    _postSeekCooldownTimer?.cancel();
    _postSeekCooldownTimer = null;
    _catalogRevision++;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    WidgetsBinding.instance.removeObserver(this);
    _stopLiveTimers();
    unawaited(_shutdownTransports().catchError((Object error) {
      debugPrint('ShuYoVOD transport teardown failure: ${error.runtimeType}');
    }));
    unawaited(_restoreOrientation());
    for (final subscription in _syncSubscriptions) {
      unawaited(subscription.cancel());
    }
    _controlsRevision.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _publish(VoidCallback update) {
    if (!mounted) return;
    update();
    // Derive a changed catalog once as part of publishing business state. The
    // widgets only read its immutable groups, numbers and display metadata.
    _episodeCatalogCache.resolve(
      lessons: _catalog,
      teachingClassId: widget.course.teachingClassId,
    );
    setState(() {});
    _controlsRevision.value++;
  }

  bool _validLesson(VodLesson lesson) =>
      recordingLessonCanSelect(lesson) &&
      lesson.teachingClassId == widget.course.teachingClassId &&
      _catalog.any((item) =>
          item.id == lesson.id &&
          item.isLive == lesson.isLive &&
          recordingLessonCanSelect(item));

  Future<void> _loadNotes(VodLesson lesson) async {
    final warning = await _notesController.load(lesson);
    if (mounted && warning != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(warning)),
      );
    }
  }

  Future<void> _loadLesson(VodLesson lesson, {bool resume = false}) async {
    final revision = ++_loadRevision;
    final enteringLive =
        lesson.isLive && (!_lesson.isLive || lesson.id != _lesson.id);
    if (enteringLive) {
      _liveProtocolSelected = false;
      _liveProtocol = _playerPreferences.defaultLiveProtocol;
    }
    _resumeRecordingRevision = null;
    _lifecycleResumePending = false;
    final drainLive = lesson.isLive || _lesson.isLive;
    _viewAudioRevision++;
    _resetSeekSynchronization();
    _openingMediaRevision = null;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    _secondaryLoading = false;
    _secondaryWaitingForMain = false;
    _pendingViewIndex = null;
    _postSeekVerifyWindow = false;
    _postSeekCooldownTimer?.cancel();
    _postSeekCooldownTimer = null;
    _liveSyncWatchdogTimer?.cancel();
    _liveSyncWatchdogTimer = null;
    _hasObservedLiveSecondaryPosition = false;
    _lastLiveRecoverAt = null;
    _liveSyncMismatchPending = false;
    if (lesson.id != _lesson.id) _preferredView = '教室';
    _publish(() {
      _lesson = lesson;
      _loading = true;
      _failure = null;
      _failureMessage = null;
      _playback = null;
    });
    unawaited(_loadNotes(lesson));
    final preparation = _transport.prepare(() async {
      if (!mounted || revision != _loadRevision) return;
      await _lifecycleQueue;
      if (!mounted || revision != _loadRevision) return;
      await _disposeRtc();
      if (!mounted || revision != _loadRevision) return;
      _stopLiveTimers();
      if (!drainLive && _liveProxy == null) {
        await _secondaryPlayer?.pause();
      }
      if (drainLive || _liveProxy != null) {
        // A native open can outlive its timeout. Stop the previous demuxer
        // before starting the next transport or removing its proxy.
        await _transport.stopAndDrain(
          stop: () async {
            await Future.wait([
              if (_player != null) _player!.stop(),
              if (_secondaryPlayer != null) _secondaryPlayer!.stop(),
            ]);
          },
          primaryQueue: _mediaQueue,
          secondaryQueue: _secondaryQueue,
          drain: drainLive,
        );
      }
      // The old opening task may have created the proxy while stop awaited.
      final oldProxy = _liveProxy;
      _liveProxy = null;
      await oldProxy?.dispose();
    });
    try {
      await preparation;
    } on Object catch (error) {
      debugPrint('ShuYoVOD transport stop failure: ${error.runtimeType}');
      if (mounted && revision == _loadRevision) {
        _publish(() {
          _loading = false;
          _failure = _PlaybackFailure.media;
        });
      }
      return;
    }
    if (!mounted || revision != _loadRevision) return;
    final oldPosition = resume && _loadedLessonId == lesson.id
        ? (_timelinePlayer ?? _player)?.state.position
        : null;
    if (!_validLesson(lesson)) {
      _publish(() {
        _loading = false;
        _failure = _PlaybackFailure.unavailable;
      });
      return;
    }
    try {
      await _player?.pause();
      if (lesson.isLive) await _playerPreferencesReady;
      if (!mounted || revision != _loadRevision) return;
      if (enteringLive && !_liveProtocolSelected) {
        _liveProtocol = _playerPreferences.defaultLiveProtocol;
      }
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
            liveEndTime: playback.liveEndTime,
            description: playback.description);
        if (_lesson.isLive && playback.liveEndTime != null) {
          _lesson = _lesson.withLiveEndTime(playback.liveEndTime!);
          _catalog = [
            for (final candidate in _catalog)
              if (candidate.id == _lesson.id && candidate.isLive)
                _lesson
              else
                candidate,
          ];
        }
        _viewIndex = selected < 0 ? 0 : selected;
      });
      if (!await _entryWork.ready || !mounted || revision != _loadRevision) {
        return;
      }
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
          VodWebVpnSessionExpiredException() => _PlaybackFailure.webVpnSession,
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
          _errorSubscription = player.stream.error
              .listen((message) => _onPlayerError(created, message));
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
          _liveProxy ??= widget.liveProxyFactory?.call(widget.repository!) ??
              VodLiveStreamProxy(
                useWebVpn: widget.repository!.useWebVpn,
                headersLoader: widget.repository!.mediaHeadersFor,
              );
          mediaUrl = await _liveProxy!.open(view.url);
          if (!mounted || revision != _loadRevision) return;
        }
        _openingMediaRevision = revision;
        _timelinePlayer = player;
        await _viewAudioQueue;
        if (!mounted || revision != _loadRevision) return;
        if (_viewVolumeInitialized) await player.setVolume(_viewVolume);
        if (!mounted || revision != _loadRevision) return;
        final openedPlayer = player;
        final nativeOpen = openedPlayer
            .open(
          Media(
            mediaUrl.toString(),
            httpHeaders: playback.isLive && _liveProxy != null
                ? const {}
                : view.httpHeaders,
            start:
                position != null && position > Duration.zero ? position : null,
          ),
          play: play && _foreground,
        )
            .then((_) async {
          // Keep this attached to the native operation itself: it may finish
          // after the UI's timeout, while a background pause has already run.
          if (!mounted || revision != _loadRevision) return;
          if (!_foreground || _failure != null) {
            await openedPlayer.pause();
          } else if (play && _resumeRecordingRevision == revision) {
            await openedPlayer.play();
            _resumeRecordingRevision = null;
            _lifecycleResumePending = false;
          }
        });
        _transport.trackOpen(nativeOpen, secondary: false);
        await nativeOpen.timeout(const Duration(seconds: 25));
        if (_openingMediaRevision == revision) _openingMediaRevision = null;
        if (!mounted || revision != _loadRevision) return;
        if (playback.isLive || rate != 1) {
          await player.setRate(playback.isLive ? 1 : rate);
        }
        if (playback.isLive) _startLiveTimers(revision);
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

  Future<void> _disposeRtc({bool waitIndefinitely = false}) async {
    _cancelRtcVolumeSubscription();
    await _transport.waitForRtcTeardown(waitIndefinitely: waitIndefinitely);
    final sessions = _rtcSessions;
    _rtcSessions = [];
    _rtcRequestedView = null;
    if (sessions.isEmpty) return;
    await _transport.teardownRtc(
      () async => Future.wait(sessions.map((session) => session.dispose())),
      waitIndefinitely: waitIndefinitely,
    );
  }

  void _cancelRtcVolumeSubscription() {
    final subscription = _rtcVolumeSubscription;
    _rtcVolumeSubscription = null;
    if (subscription != null) {
      // Stream cancellation owns no native RTC resources. Revision and session
      // guards already reject late events, so it must not delay teardown.
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  Future<void> _shutdownTransports() => _transport.prepare(() async {
        await _lifecycleQueue;
        Object? rtcError;
        StackTrace? rtcStack;
        try {
          await _disposeRtc(waitIndefinitely: true);
        } on Object catch (error, stack) {
          // A failed RTC cleanup must not skip the independent media player.
          rtcError = error;
          rtcStack = stack;
        }
        await _transport.stopAndDrain(
          stop: () async {
            await Future.wait([
              if (_player != null) _player!.stop(),
              if (_secondaryPlayer != null) _secondaryPlayer!.stop(),
            ]);
          },
          primaryQueue: _mediaQueue,
          secondaryQueue: _secondaryQueue,
          drain: true,
          waitIndefinitely: true,
        );
        final proxy = _liveProxy;
        _liveProxy = null;
        await proxy?.dispose();
        // The route releases its decoders only after outstanding native opens
        // and their final stop have actually completed.
        await Future.wait([
          _releasePlayer(_secondaryPlayer, _secondaryErrorSubscription),
          _releasePlayer(_player, _errorSubscription),
        ]);
        if (rtcError != null) Error.throwWithStackTrace(rtcError, rtcStack!);
      });

  Future<void> _checkRtcSecondarySync() async {
    if (!mounted || !_foreground || !_isWebRtc || _rtcSessions.length < 2) {
      return;
    }
    final primaryIndex = _viewIndex;
    final secondaryIndex = primaryIndex == 0 ? 1 : 0;
    if (secondaryIndex >= _rtcSessions.length) return;
    final primary = _rtcSessions[primaryIndex];
    final secondary = _rtcSessions[secondaryIndex];
    if (primary.state.value == VodWebRtcState.playing &&
        secondary.state.value == VodWebRtcState.paused) {
      try {
        await secondary.setAudioEnabled(false);
        await secondary.play();
      } on Object {
        // Transparent best-effort recovery for the secondary stream.
      }
    } else if (primary.state.value == VodWebRtcState.paused &&
        secondary.state.value == VodWebRtcState.playing) {
      try {
        await secondary.pause();
      } on Object {
        // Transparent best-effort recovery for the secondary stream.
      }
    }
  }

  Future<void> _pauseRtc() async {
    for (final session in _rtcSessions.toList()) {
      await session.pause();
    }
  }

  Future<void> _playRtc() async {
    final primaryIndex = _viewIndex;
    for (var i = 0; i < _rtcSessions.length; i++) {
      await _rtcSessions[i].setAudioEnabled(i == primaryIndex);
    }
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
      _errorSubscription = player.stream.error
          .listen((message) => _onPlayerError(created, message));
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
        .map((view) =>
            widget.webRtcSessionFactory?.call(view.webRtcSource!) ??
            VodWebRtcSession(view.webRtcSource!))
        .toList(growable: false);
    _rtcSessions = sessions;
    _cancelRtcVolumeSubscription();
    if (!_viewVolumeInitialized) {
      _viewVolume = player.state.volume;
      _viewVolumeInitialized = true;
    }
    _rtcVolumeSubscription = player.stream.volume.listen((volume) {
      if (!mounted ||
          revision != _loadRevision ||
          !identical(_rtcSessions, sessions)) {
        return;
      }
      _viewVolume = volume;
      _viewVolumeInitialized = true;
      unawaited(() async {
        try {
          await Future.wait(
              sessions.map((session) => session.setVolume(volume)));
        } on Object {
          debugPrint('ShuYoVOD WebRTC volume update failed');
        }
      }());
    });
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
            if (state == VodWebRtcState.connecting ||
                state == VodWebRtcState.idle) {
              _loading = true;
              _failure = null;
              _failureMessage = null;
            } else if (state == VodWebRtcState.playing ||
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
        if (index == _viewIndex && state == VodWebRtcState.playing) {
          unawaited(_checkRtcSecondarySync());
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
      if (!mounted || revision != _loadRevision) return;
      await sessions[index].setVolume(_viewVolume);
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
    _startLiveTimers(revision);
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
    await BackgroundWorkGate.idle;
    if (!mounted || revision != _loadRevision) return;
    await _openSecondary();
  }

  Future<void> _alignSecondaryStart(Player secondary, int revision) async {
    var active = true;
    Completer<void>? pendingPosition;
    StreamSubscription<Duration>? subscription;
    bool current() => active && mounted && revision == _secondaryRevision;
    bool matches(Duration position, Duration target) =>
        (position - target).abs() <= const Duration(milliseconds: 250);
    try {
      await (() async {
        while (current()) {
          final seekRevision = _seekSyncRevision;
          final target =
              _seekSyncTarget ?? (_timelinePlayer ?? _player!).state.position;
          if (matches(secondary.state.position, target)) return;
          final completion = Completer<void>();
          pendingPosition = completion;
          subscription = secondary.stream.position.listen((position) {
            if (current() &&
                !completion.isCompleted &&
                matches(position, target)) {
              completion.complete();
            }
          });
          await secondary.seek(target);
          if (!current()) return;
          if (!completion.isCompleted &&
              matches(secondary.state.position, target)) {
            completion.complete();
          }
          await completion.future;
          unawaited(subscription!.cancel());
          subscription = null;
          if (seekRevision != _seekSyncRevision) continue;
        }
      })()
          .timeout(recordingSeekPositionTimeout);
    } finally {
      active = false;
      if (pendingPosition?.isCompleted == false) pendingPosition!.complete();
      if (subscription != null) unawaited(subscription!.cancel());
    }
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
    unawaited(_selectView(next));
  }

  Future<void> _selectView(int index) async {
    final playback = _playback;
    if (playback == null ||
        index < 0 ||
        index >= playback.views.length ||
        _loading) {
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
    if (!_viewVolumeInitialized) {
      _viewVolume = _player!.state.volume;
      _viewVolumeInitialized = true;
    }
    _publish(() {
      final primary = _player;
      final controller = _videoController;
      final errorSubscription = _errorSubscription;
      _player = _secondaryPlayer;
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
    _routeViewAudio();
  }

  void _routeViewAudio() {
    _viewAudioRevision++;
    if (_routingViewAudio) return;
    _routingViewAudio = true;
    _viewAudioQueue = () async {
      var retried = false;
      try {
        while (mounted) {
          final primary = _player;
          final secondary = _secondaryPlayer;
          if (primary == null || secondary == null) return;
          final revision = _viewAudioRevision;
          try {
            await secondary.setVolume(0);
            if (!mounted || revision != _viewAudioRevision) continue;
            await primary.setVolume(_viewVolume);
          } on Object {
            if (revision != _viewAudioRevision) continue;
            if (!retried) {
              retried = true;
              continue;
            }
            if (mounted) {
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(const SnackBar(content: Text('切换视角音量失败，请重试')));
            }
            return;
          }
          if (revision == _viewAudioRevision) return;
          retried = false;
        }
      } finally {
        _routingViewAudio = false;
      }
    }();
    unawaited(_viewAudioQueue);
  }

  void _onPlayerError(Player source, [String? message]) {
    if (message != null) {
      final diagnostic =
          message.replaceAll(RegExp(r'(?:https?|wss?)://[^\s]+'), '<media>');
      debugPrint('ShuYoVOD native playback error: $diagnostic');
    }
    // Android's media_kit VideoController seeks to the current position when
    // its Surface changes. Non-seekable live streams reject that advisory
    // operation while continuing to decode; it is not a playback failure.
    if (_lesson.isLive &&
        message != null &&
        (message.trim() == 'Cannot seek in this stream.' ||
            message.contains("You can force it with '--force-seekable=yes'"))) {
      return;
    }
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
      _publish(() {
        _secondaryFailed = true;
        if (identical(source, _timelinePlayer)) _timelinePlayer = _player;
      });
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
    final secondary = _secondaryPlayer;
    final timeline = _timelinePlayer;
    if (timedOut &&
        primary != null &&
        timeline != null &&
        !_seekAwaitingPosition.contains(primary) &&
        _seekAwaitingPosition.contains(timeline)) {
      _publish(() => _timelinePlayer = primary);
    }
    final secondaryTimedOut = timedOut &&
        secondary != null &&
        _seekAwaitingPosition.contains(secondary);
    _resetSeekSynchronization();
    if (mounted && !_lesson.isLive) {
      // Enable post-seek drift supervision. When secondary timed out while
      // primary converged, immediately enforce a fallback seek onto secondary
      // so the main view never rewinds and secondary snaps to primary.
      _postSeekVerifyWindow = true;
      unawaited(_alignSecondary(forcePositionCheck: secondaryTimedOut));
    }
  }

  void _observeSeekPosition(Player player, Duration position) {
    if (_lesson.isLive && identical(player, _secondaryPlayer)) {
      _hasObservedLiveSecondaryPosition = true;
    }
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
    final includeSecondary = secondary != null &&
        _secondaryViewIndex != null &&
        !_secondaryLoading &&
        !_secondaryFailed;
    final players = <Player>[
      primary,
      if (includeSecondary) secondary,
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
    var recoveredPreviewSession = false;
    if (_failure == _PlaybackFailure.session ||
        _failure == _PlaybackFailure.webVpnSession) {
      final recover = _failure == _PlaybackFailure.webVpnSession
          ? widget.onWebVpnSessionExpired ?? widget.onSessionExpired
          : widget.onSessionExpired;
      if (recover == null) return;
      _publish(() {
        _recovering = true;
        if (widget.loadPreviewCatalog) {
          // A request issued under the old session may complete after login.
          _catalogRevision++;
          _catalogLoading = false;
        }
      });
      var recovered = false;
      try {
        recovered = await recover();
      } on Object {
        // Recovery details may contain credentials or signed URLs.
      }
      if (!mounted) return;
      _publish(() => _recovering = false);
      if (!recovered) return;
      _notesController.invalidate();
      recoveredPreviewSession = widget.loadPreviewCatalog;
    }
    if (widget.repository != null && !_validLesson(_lesson)) {
      await _loadCatalog(forceRefresh: true);
    } else {
      final playback = _loadLesson(_lesson, resume: !_lesson.isLive);
      if (recoveredPreviewSession) {
        unawaited(_loadCatalog(forceRefresh: true));
      }
      await playback;
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
    final unchanged = value == _dualEnabled;
    _setPlayerPreferences(_playerPreferences.copyWith(secondaryView: value));
    if (unchanged) _warmSecondaryWhenEnabled(value);
  }

  void _warmSecondaryWhenEnabled(bool value) {
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
    _hasObservedLiveSecondaryPosition = false;
    _postSeekVerifyWindow = false;
    _postSeekCooldownTimer?.cancel();
    _postSeekCooldownTimer = null;
    _lastLiveRecoverAt = null;
    _liveSyncMismatchPending = false;
    final view = playback.views[index];
    _publish(() {
      _secondaryLoading = true;
      _secondaryFailed = false;
    });
    _secondaryQueue = _secondaryQueue.then((_) async {
      if (!await _entryWork.ready ||
          !mounted ||
          revision != _secondaryRevision) {
        return;
      }
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
          _secondaryErrorSubscription = secondary.stream.error
              .listen((message) => _onPlayerError(created, message));
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
        if (!mounted || revision != _secondaryRevision) return;
        final openedPlayer = secondary;
        final nativeOpen = openedPlayer
            .open(
                Media(url.toString(),
                    httpHeaders: playback.isLive && _liveProxy != null
                        ? const {}
                        : view.httpHeaders,
                    start: playback.isLive ? null : _player?.state.position),
                play: _foreground && (_player?.state.playing ?? false))
            .then((_) async {
          if (!mounted || revision != _secondaryRevision) return;
          if (!_foreground || _secondaryFailed || _failure != null) {
            await openedPlayer.pause();
          }
        });
        _transport.trackOpen(nativeOpen, secondary: true);
        await nativeOpen.timeout(const Duration(seconds: 25));
        if (!mounted || revision != _secondaryRevision) return;
        await secondary.setRate(_player?.state.rate ?? 1);
        await _waitForVideoOutput(_secondaryController!)
            .timeout(const Duration(seconds: 20));
        if (!mounted || revision != _secondaryRevision) {
          await secondary.pause();
          return;
        }
        if (!playback.isLive) {
          await _alignSecondaryStart(secondary, revision);
          if (!mounted || revision != _secondaryRevision) return;
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

  static const _recordingSeekDriftTolerance = Duration(seconds: 1);
  static const _livePositionTolerance = Duration(seconds: 2);
  static const _positionCorrectionCooldown = Duration(milliseconds: 1200);
  static const _liveRecoverCooldown = Duration(seconds: 10);

  bool _shouldCorrectRecordingAfterSeek(
    Player primary,
    Player secondary, {
    required bool force,
  }) {
    if (_lesson.isLive || !_postSeekVerifyWindow) return false;
    if (!force && (primary.state.buffering || secondary.state.buffering)) {
      return false;
    }
    if (_postSeekCooldownTimer?.isActive ?? false) return false;
    final drift = (secondary.state.position - primary.state.position).abs();
    return drift > _recordingSeekDriftTolerance;
  }

  Future<void> _alignSecondary({bool forcePositionCheck = false}) async {
    if (_isWebRtc) {
      await _checkRtcSecondarySync();
      return;
    }
    if (_syncingSecondary) {
      _secondarySyncPending = true;
      await _secondarySyncCompletion?.future;
      return;
    }
    final primary = _player;
    final secondary = _secondaryPlayer;
    final revision = _secondaryRevision;
    if (_secondaryLoading ||
        _secondaryFailed ||
        !_foreground ||
        _loading ||
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
        !_loading &&
        !_seekingPlayers;
    try {
      final timeline = _lesson.isLive ? primary : _timelinePlayer ?? primary;
      final follower = identical(timeline, primary) ? secondary : primary;
      if (follower.state.rate != timeline.state.rate) {
        await follower.setRate(timeline.state.rate);
        if (!stillCurrent()) return;
      }
      if (!stillCurrent()) return;
      if (timeline.state.playing != follower.state.playing) {
        if (timeline.state.playing) {
          await follower.play();
        } else {
          await follower.pause();
        }
        if (!stillCurrent()) return;
      }
      if (!_lesson.isLive &&
          _shouldCorrectRecordingAfterSeek(primary, secondary,
              force: forcePositionCheck)) {
        // Fallback: after a seek, if the secondary view diverged from the
        // primary view, snap the secondary view to the primary position
        // transparently without altering the primary playback.
        final target = primary.state.position;
        _postSeekVerifyWindow = false;
        _postSeekCooldownTimer?.cancel();
        _postSeekCooldownTimer = Timer(_positionCorrectionCooldown, () {
          _postSeekCooldownTimer = null;
        });
        await secondary.seek(target);
        if (!stillCurrent()) return;
      } else if (_lesson.isLive &&
          _playback != null &&
          _secondaryViewIndex != null &&
          !_secondaryLoading &&
          !_secondaryFailed) {
        final primaryPos = primary.state.position;
        final secondaryPos = secondary.state.position;
        if (_hasObservedLiveSecondaryPosition &&
            primary.state.playing &&
            !primary.state.buffering &&
            !secondary.state.buffering &&
            primaryPos > Duration.zero &&
            secondaryPos > Duration.zero &&
            (primaryPos - secondaryPos).abs() > _livePositionTolerance) {
          if (_liveSyncMismatchPending) {
            final now = DateTime.now();
            if (_lastLiveRecoverAt == null ||
                now.difference(_lastLiveRecoverAt!) >= _liveRecoverCooldown) {
              _lastLiveRecoverAt = now;
              _liveSyncMismatchPending = false;
              // Reopen only the secondary stream silently at the live edge
              // without interrupting the primary stream.
              unawaited(_realignLiveSecondary());
            }
          } else {
            _liveSyncMismatchPending = true;
          }
        } else {
          _liveSyncMismatchPending = false;
        }
      }
    } on Object {
      if (stillCurrent()) _publish(() => _secondaryFailed = true);
    } finally {
      _syncingSecondary = false;
      _secondarySyncCompletion = null;
      completion.complete();
      if (_secondarySyncPending) {
        _secondarySyncPending = false;
        unawaited(_alignSecondary(forcePositionCheck: forcePositionCheck));
      }
      final pending = _pendingViewIndex;
      if (pending != null) {
        unawaited(_selectView(pending));
      }
    }
  }

  Future<void> _realignLiveSecondary() async {
    final playback = _playback;
    final secondary = _secondaryPlayer;
    final index = _secondaryViewIndex;
    final revision = _secondaryRevision;
    if (!mounted ||
        !_foreground ||
        !_lesson.isLive ||
        _isWebRtc ||
        playback == null ||
        secondary == null ||
        index == null ||
        index < 0 ||
        index >= playback.views.length ||
        _secondaryLoading ||
        _secondaryFailed) {
      return;
    }
    try {
      final view = playback.views[index];
      final url =
          _liveProxy != null ? await _liveProxy!.open(view.url) : view.url;
      if (!mounted || revision != _secondaryRevision) return;
      final openWork = secondary.open(
        Media(
          url.toString(),
          httpHeaders: _liveProxy != null ? const {} : view.httpHeaders,
        ),
        play: _foreground && (_player?.state.playing ?? false),
      );
      _transport.trackOpen(openWork, secondary: true);
      await openWork.timeout(const Duration(seconds: 25));
      if (!mounted || revision != _secondaryRevision) return;
      await secondary.setVolume(0);
    } on Object {
      // Transparent fallback: keep primary uninterrupted; if secondary stops
      // recovering, leave it for user toggle or next natural reconnect.
    }
  }

  Widget _secondaryView({bool renderVideo = true}) => ColoredBox(
      color: renderVideo ? Colors.black : Colors.transparent,
      child: Stack(fit: StackFit.expand, children: [
        if (_isWebRtc && _rtcSessions.length > 1)
          RTCVideoView(_rtcSessions[_viewIndex == 0 ? 1 : 0].renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
        else if (renderVideo && !_isWebRtc && _secondaryController != null)
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
                          pauseUponEnteringBackgroundMode: false,
                          resumeUponEnteringForegroundMode: false,
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
                              timelinePlayer:
                                  _lesson.isLive ? null : _timelinePlayer,
                              viewControllers: kIsWeb || _isWebRtc
                                  ? const []
                                  : [
                                      _hostVideoController!,
                                      if (_secondaryController != null)
                                        identical(_videoController,
                                                _hostVideoController)
                                            ? _secondaryController!
                                            : _videoController!,
                                    ],
                              primaryController: _videoController,
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
                              termLabel: _compactTermLabel,
                              onBack: () => Navigator.of(context).maybePop(),
                              onEpisodePanelVisibilityChanged: (visible) =>
                                  _episodePanelVisible = visible,
                              lessons: _lessons,
                              episodeLessons: _filteredLessons,
                              episodeNewestFirst: _episodesNewestFirst,
                              onEpisodeOrderChanged: (value) =>
                                  _publish(() => _episodesNewestFirst = value),
                              onClearClassroomFilter: _showCurrentClassroom,
                              selectedLessonId: _lesson.id,
                              selectedLesson: _lesson.id > 0 ? _lesson : null,
                              onLessonSelected: (lesson) =>
                                  unawaited(_loadLesson(lesson)),
                              dualEnabled: _dualEnabled,
                              onDualChanged: kIsWeb ? null : _setDualEnabled,
                              secondaryView: _secondaryView(
                                  renderVideo: kIsWeb || _isWebRtc),
                              secondaryLabel: (_playback?.views.length ?? 0) > 1
                                  ? _playback!
                                      .views[_viewIndex == 0 ? 1 : 0].label
                                  : '',
                              onSwapViews: _requestSwap,
                              aspect: _aspect,
                              onAspectChanged: _changeAspect,
                              loading: _loading,
                              isLive: _lesson.isLive,
                              preferences: _playerPreferences,
                              onPreferencesChanged: _setPlayerPreferences,
                              informationLoader: _readPlaybackInformation,
                              livePlaying: _isWebRtc ? _rtcPlaying : null,
                              onLiveTogglePlayback: _isWebRtc
                                  ? () => unawaited(_toggleRtcPlayback())
                                  : null,
                              liveProtocol: _liveProtocol,
                              liveResolutionLabel: _webRtcResolutionLabel(),
                              onLiveProtocolChanged: widget.repository == null
                                  ? null
                                  : (protocol) {
                                      if (protocol == _liveProtocol) return;
                                      _publish(() {
                                        _liveProtocolSelected = true;
                                        _liveProtocol = protocol;
                                      });
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
                final topInset = MediaQuery.viewPaddingOf(context).top;
                if (portrait) {
                  _portraitViewport = constraints.biggest;
                  _portraitMediaQuery = MediaQuery.of(context);
                }
                final portraitViewport = _portraitViewport;
                final portraitMediaQuery = _portraitMediaQuery;
                // Retain the portrait layout tree behind fullscreen so that an
                // open detail panel and its scroll position are preserved.
                return Stack(fit: StackFit.expand, children: [
                  if (portraitViewport != null && portraitMediaQuery != null)
                    Offstage(
                      key: const ValueKey('recording-portrait-content'),
                      offstage: !portrait,
                      child: TickerMode(
                        enabled: portrait,
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: portraitViewport.width,
                          maxWidth: portraitViewport.width,
                          minHeight: portraitViewport.height,
                          maxHeight: portraitViewport.height,
                          child: MediaQuery(
                            data: portraitMediaQuery,
                            child: SizedBox.fromSize(
                              size: portraitViewport,
                              child: _portraitLayout(
                                colors,
                                video:
                                    portrait ? video : const SizedBox.shrink(),
                                size: portraitViewport,
                                topInset: portraitMediaQuery.viewPadding.top,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!portrait && constraints.maxWidth >= 1000)
                    Padding(
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
                            SizedBox(
                                width: 360,
                                child: _lessonList(colors, nested: false)),
                          ],
                        ),
                      ),
                    ),
                  if (!portrait && constraints.maxWidth < 1000)
                    Padding(
                      padding: EdgeInsets.only(top: topInset),
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: Column(children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: math.max(100.0,
                                  (constraints.maxHeight - topInset) * .6),
                            ),
                            child:
                                AspectRatio(aspectRatio: 16 / 9, child: video),
                          ),
                          Expanded(child: _lessonList(colors, nested: false)),
                        ]),
                      ),
                    ),
                ]);
              }))),
    );
  }

  Widget _portraitLayout(ShuYoColors colors,
      {required Widget video, required Size size, required double topInset}) {
    final videoHeight = math.min(
        size.width * 9 / 16, math.max(100.0, (size.height - topInset) * .6));
    return RecordingPlayerLayout(
      detailScope: _lesson.id,
      video: video,
      tabBar: _portraitTabs(),
      body: _portraitBody(colors),
      expandedHeight: videoHeight,
      topInset: topInset,
      player: _lesson.isLive ? _player : _timelinePlayer ?? _player,
      playingOverride: _isWebRtc ? _rtcPlaying : null,
      loading: _loading || _recovering,
      canResume: !_loading && _failure == null && _playback != null,
      onResume: () async {
        if (_isWebRtc) {
          await _playRtc();
          return;
        }
        final player = _lesson.isLive ? _player : _timelinePlayer ?? _player;
        if (player?.state.completed ?? false) {
          await _seekPlayers(Duration.zero);
        }
        await player?.play();
      },
      onBack: () => Navigator.of(context).maybePop(),
      onMore: () => unawaited(_openCollapsedMenu()),
    );
  }

  Widget _portraitBody(ShuYoColors colors) {
    final canSeek =
        !_loading && _failure == null && _playback != null && !_lesson.isLive;
    final signature = (
      _lesson.id,
      _episodeCatalog,
      _activeClassroom,
      _episodesNewestFirst,
      _catalogLoading,
      _playback?.description,
      canSeek,
      colors,
    );
    final cached = _portraitBodyCache;
    if (cached != null && cached.$1 == signature) return cached.$2;
    final body = RepaintBoundary(
        child: TabBarView(
      controller: _tabController,
      children: [
        _PlayerTab(
          controller: _tabController,
          index: 0,
          child: _lessonList(colors, nested: true),
        ),
        _PlayerTab(
          controller: _tabController,
          index: 1,
          scrollIdentity: _lesson.id,
          child: ValueListenableBuilder<RecordingNotesState>(
            valueListenable: _notesController,
            builder: (context, notes, _) => RecordingNotesPanel(
              key: ValueKey('recording-notes:${_lesson.id}'),
              nested: true,
              isLive: _lesson.isLive,
              slides: notes.slides,
              loading:
                  notes.loading || notes.lessonId == null && _catalogLoading,
              error: notes.lessonId == null ? '请先选择课次，再查看 PPT 笔记' : notes.error,
              canSeek: canSeek,
              onSeek: (position) {
                if (!_loading &&
                    _failure == null &&
                    _playback != null &&
                    !_lesson.isLive) {
                  unawaited(_seekPlayers(position));
                }
              },
              headersLoader: widget.repository?.mediaHeadersFor,
            ),
          ),
        ),
      ],
    ));
    _portraitBodyCache = (signature, body);
    return body;
  }

  PreferredSizeWidget _portraitTabs() => _portraitTabBar ??= PreferredSize(
        preferredSize: const Size.fromHeight(45),
        child: ValueListenableBuilder<RecordingNotesState>(
          valueListenable: _notesController,
          builder: (context, notes, _) => RecordingPlayerTabs(
            controller: _tabController,
            noteCount: _lesson.isLive ? 0 : notes.count,
          ),
        ),
      );

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
        action: widget.repository == null || !_shouldLoadCatalog
            ? null
            : TextButton.icon(
                onPressed: () => unawaited(_loadCatalog(forceRefresh: true)),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新选集'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
      );
    }
    final webVpnSession = _failure == _PlaybackFailure.webVpnSession;
    final session = _failure == _PlaybackFailure.session || webVpnSession;
    final message = (webVpnSession ? null : _failureMessage) ??
        switch (_failure) {
          _PlaybackFailure.webVpnSession => 'WebVPN 连接已失效，请恢复连接后重试',
          _PlaybackFailure.session => '校园账户登录已失效，请重新登录。',
          _PlaybackFailure.permission =>
            _lesson.isLive ? '当前账号没有这节直播的观看权限。' : '无法获取这节录播的播放地址，请稍后重试。',
          _PlaybackFailure.network => '暂时无法连接录播平台，请检查网络后重试。',
          _PlaybackFailure.media => '视频暂时无法播放，可刷新播放地址后重试。',
          _ => _lesson.isLive ? '直播暂时无法观看或已结束，请刷新重试。' : '这节录播暂时无法观看，请稍后重试。',
        };
    return RecordingPlaybackMessage(
      icon: Icons.error_outline_rounded,
      message: message,
      action: session &&
              (webVpnSession
                      ? widget.onWebVpnSessionExpired ?? widget.onSessionExpired
                      : widget.onSessionExpired) ==
                  null
          ? null
          : TextButton.icon(
              onPressed: () => unawaited(_retry()),
              icon: Icon(
                  webVpnSession
                      ? Icons.vpn_key_outlined
                      : session
                          ? Icons.login
                          : Icons.refresh,
                  size: 18),
              label: Text(webVpnSession
                  ? '恢复连接'
                  : session
                      ? '重新登录'
                      : '重试'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
    );
  }

  Widget _lessonHeading(ShuYoColors colors) {
    final days = _classroomEpisodes.overviewDays;
    return Padding(
      key: const ValueKey('recording-course-banner'),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        RecordingCourseTitle(course: widget.course, large: true),
        if (days.isNotEmpty) ...[
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12), child: Divider()),
          RecordingCourseOverview(days: days, term: _courseTerm),
          const Padding(padding: EdgeInsets.only(top: 12), child: Divider()),
        ],
        if (_playback?.description.isNotEmpty ?? false) ...[
          const SizedBox(height: 10),
          Text(_playback!.description,
              style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary)),
        ],
      ]),
    );
  }

  Widget _lessonList(ShuYoColors colors, {required bool nested}) {
    // First layout of the overview and month slivers must not compete with
    // every frame of the push animation. The video shell stays responsive;
    // this stable route's contents are built once the transition has settled.
    if (!_entryContentReady) return const SizedBox.expand();
    final episodeKeys = nested ? _episodeKeys : _landscapeEpisodeKeys;
    final headingKey =
        nested ? _episodeHeadingKey : _landscapeEpisodeHeadingKey;
    final signature = (
      _episodeCatalog,
      _activeClassroom,
      _episodesNewestFirst,
      _catalogLoading,
      _lesson.id,
      _playback?.description,
      colors,
      MediaQuery.viewPaddingOf(context).bottom,
    );
    final cached = _lessonListCache[nested];
    if (cached != null && cached.$1 == signature) return cached.$2;
    final chronological = _lessons;
    final episodes = _classroomEpisodes;
    final lessons =
        _episodesNewestFirst ? episodes.newestFirst : episodes.oldestFirst;
    final episodeNumbers = episodes.episodeNumbers;
    final months =
        _episodesNewestFirst ? episodes.newestMonths : episodes.oldestMonths;
    final content = CustomScrollView(
      key: const ValueKey('course-player-episodes'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (nested)
          SliverLayoutBuilder(
              builder: (context, constraints) => SliverOverlapInjector(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                      context))),
        if (_catalogLoading)
          const SliverToBoxAdapter(
              child: LinearProgressIndicator(
                  key: ValueKey('recording-catalog-progress'), minHeight: 2)),
        SliverToBoxAdapter(key: headingKey, child: _lessonHeading(colors)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _EpisodeHeader(
            colors: colors,
            title: '选集',
            classroomFilter: _classrooms.length < 2 ? null : _classroomFilter(),
            newestFirst: _episodesNewestFirst,
            hasLessons: lessons.isNotEmpty,
            hasCurrent: chronological.any((lesson) => lesson.id == _lesson.id),
            onFirst: () => _scrollToEpisode(lessons.first.id,
                alignment: .5, nested: nested),
            onLast: () =>
                _scrollToEpisode(lessons.last.id, alignment: 1, nested: nested),
            onCurrent: () =>
                _scrollToEpisode(_lesson.id, alignment: .5, nested: nested),
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
        for (final month in months)
          SliverMainAxisGroup(
            key: ValueKey('recording-episode-month-group:${month.month}'),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _EpisodeMonthHeader(month: month.month),
              ),
              SliverList.builder(
                itemCount: month.lessons.length,
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<int>) return null;
                  return month.indexByLessonId[key.value];
                },
                itemBuilder: (context, index) {
                  final lesson = month.lessons[index];
                  return KeyedSubtree(
                    key: ValueKey(lesson.id),
                    child: Column(
                      key: episodeKeys.putIfAbsent(lesson.id, GlobalKey.new),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RecordingEpisodeTile(
                          tileKey: ValueKey('recording-lesson-${lesson.id}'),
                          lesson: lesson,
                          metadata: _episodeCatalog.metadataFor(lesson),
                          number: episodeNumbers[lesson.id]!,
                          selected: lesson.id == _lesson.id,
                          onTap: !recordingLessonCanSelect(lesson) ||
                                  lesson.id == _lesson.id
                              ? null
                              : () => unawaited(_loadLesson(lesson)),
                        ),
                        if (lesson.id != lessons.last.id)
                          const Divider(indent: 16, endIndent: 16),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        SliverToBoxAdapter(
            child: SizedBox(
                height: 24 + MediaQuery.viewPaddingOf(context).bottom)),
      ],
    );
    // Android's stretch indicator transforms the entire inner viewport,
    // including pinned slivers, pushing the episode toolbar behind the tabs.
    // Keep the viewport rigid while its content still scrolls normally.
    final viewport = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: content,
    );
    // Pull-to-refresh is intentionally absent: the catalog is reconciled with
    // the server when the page opens and after a lesson ends, so a manual
    // gesture would only duplicate work and interrupt playback.
    _lessonListCache[nested] = (signature, viewport);
    return viewport;
  }

  void _scrollToEpisode(int id,
      {required double alignment, required bool nested}) {
    if (_lessons.any((lesson) => lesson.id == id) &&
        !_filteredLessons.any((lesson) => lesson.id == id)) {
      _showCurrentClassroom();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToEpisode(id, alignment: alignment, nested: nested);
        }
      });
      return;
    }
    unawaited(_revealEpisode(id,
        alignment: alignment,
        nested: nested,
        revision: ++_episodeNavigationRevision));
  }

  Future<void> _revealEpisode(int id,
      {required double alignment,
      required bool nested,
      required int revision}) async {
    final episodeKeys = nested ? _episodeKeys : _landscapeEpisodeKeys;
    final headingKey =
        nested ? _episodeHeadingKey : _landscapeEpisodeHeadingKey;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    // Rows outside the viewport are deliberately unmounted. Estimate their
    // position from a laid-out row, then let ensureVisible perform the final
    // adjustment once the target has entered the lazy viewport. This keeps
    // toolbar navigation without laying out every episode on every frame.
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted || revision != _episodeNavigationRevision) return;
      final heading = headingKey.currentContext;
      if (heading == null || !heading.mounted) return;
      final position = Scrollable.of(heading).position;
      final filtered = _filteredLessons;
      final lessons = _episodesNewestFirst
          ? filtered
          : filtered.reversed.toList(growable: false);
      final targetIndex = lessons.indexWhere((lesson) => lesson.id == id);
      if (targetIndex < 0) return;
      final target = episodeKeys[id]?.currentContext;
      if (target != null && target.mounted) {
        if (alignment == 1) {
          // Grouped pinned headers affect ensureVisible's end alignment.
          if (duration == Duration.zero) {
            position.jumpTo(position.maxScrollExtent);
          } else {
            await position.animateTo(position.maxScrollExtent,
                duration: duration, curve: Curves.easeOut);
          }
        } else {
          await Scrollable.ensureVisible(target,
              alignment: alignment, duration: duration, curve: Curves.easeOut);
        }
        return;
      }

      var nearestIndex = -1;
      RenderBox? nearestBox;
      for (var index = 0; index < lessons.length; index++) {
        final box =
            episodeKeys[lessons[index].id]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        if (nearestIndex < 0 ||
            (index - targetIndex).abs() < (nearestIndex - targetIndex).abs()) {
          nearestIndex = index;
          nearestBox = box;
        }
      }
      if (nearestBox == null) return;
      final viewport = RenderAbstractViewport.of(nearestBox);
      final estimate = viewport.getOffsetToReveal(nearestBox, 0).offset +
          (targetIndex - nearestIndex) * nearestBox.size.height;
      final offset =
          estimate.clamp(position.minScrollExtent, position.maxScrollExtent);
      position.jumpTo(offset);
      await WidgetsBinding.instance.endOfFrame;
    }
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

class _PlayerTab extends StatefulWidget {
  const _PlayerTab({
    required this.controller,
    required this.index,
    required this.child,
    this.scrollIdentity,
  });

  final TabController controller;
  final int index;
  final Object? scrollIdentity;
  final Widget child;

  @override
  State<_PlayerTab> createState() => _PlayerTabState();
}

class _PlayerTabState extends State<_PlayerTab>
    with AutomaticKeepAliveClientMixin {
  late bool _active = widget.controller.index == widget.index;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(_PlayerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTabChanged);
      widget.controller.addListener(_onTabChanged);
    }
    _active = widget.controller.index == widget.index;
  }

  void _onTabChanged() {
    final active = widget.controller.index == widget.index;
    // TabController also notifies at animation completion. Reparent the inner
    // scroll controller only when the selected page actually changes.
    if (_active != active) setState(() => _active = active);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTabChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final nestedController = PrimaryScrollController.of(context);
    final child = TickerMode(
      enabled: _active,
      child: RepaintBoundary(
        child: KeyedSubtree(
          key: PageStorageKey(
              ('recording-player-tab', widget.index, widget.scrollIdentity)),
          child: widget.child,
        ),
      ),
    );
    // Inactive kept-alive tabs retain their positions without receiving the
    // visible page's NestedScrollView drag or animating hidden loading widgets.
    return _active
        ? PrimaryScrollController(controller: nestedController, child: child)
        : PrimaryScrollController.none(child: child);
  }
}

class _EpisodeMonthHeader extends SliverPersistentHeaderDelegate {
  const _EpisodeMonthHeader({required this.month});

  final (int, int)? month;

  @override
  double get minExtent => 34;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final date = month;
    return Material(
      key: ValueKey('recording-episode-month:$date'),
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              date == null ? '日期未知' : '${date.$1}年${date.$2}月',
              style: ShuYoTextStyles.meta(
                color: context.shuyoColors.textSecondary,
                size: 12.5,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_EpisodeMonthHeader oldDelegate) =>
      month != oldDelegate.month;
}

class _EpisodeHeader extends SliverPersistentHeaderDelegate {
  _EpisodeHeader(
      {required this.colors,
      required this.title,
      required this.classroomFilter,
      required this.newestFirst,
      required this.hasLessons,
      required this.hasCurrent,
      required this.onFirst,
      required this.onLast,
      required this.onCurrent,
      required this.onReverse});

  final ShuYoColors colors;
  final String title;
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
                Text(title,
                    style: ShuYoTextStyles.sectionTitle(
                        color: colors.textPrimary)),
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
