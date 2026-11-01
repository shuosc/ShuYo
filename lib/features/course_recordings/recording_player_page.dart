import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
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
import 'recording_episode_sort_icon.dart';
import 'recording_playback_status.dart';
import 'recording_notes_panel.dart';
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
    this.loadPlayback,
    this.loadNotes,
    this.repository,
    this.onSessionExpired,
    this.playerFactory,
    this.videoControllerFactory,
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
  final Future<VodPlayback> Function(VodLesson)? loadPlayback;
  final Future<List<VodPptSlide>> Function(int courseId)? loadNotes;
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
  final _controlsRevision = ValueNotifier(0);
  late final TabController _tabController;
  List<VodPptSlide> _notes = const [];
  int? _notesLessonId;
  int _notesRevision = 0;
  bool _notesLoading = false;
  String? _notesError;
  RecordingPlayerPreferences _playerPreferences =
      const RecordingPlayerPreferences();
  Future<void> _preferencesQueue = Future<void>.value();
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
  bool _resumeLive = false;
  bool _heartbeatPending = false;
  bool _catalogLoading = false;
  bool _catalogPullRefreshing = false;
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

  Future<List<RecordingPlaybackInfoEntry>> _readPlaybackInformation() async {
    final view = _playback?.views.elementAtOrNull(_viewIndex);
    if (_isWebRtc && _viewIndex < _rtcSessions.length) {
      final session = _rtcSessions[_viewIndex];
      final details = await session.playbackInformation();
      return [
        (
          title: 'Resolution',
          value:
              '${session.renderer.videoWidth}x${session.renderer.videoHeight}'
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
    _publish(() => _playerPreferences = preferences);
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

  List<VodLesson> get _lessons => _catalog
      .where((lesson) =>
          (lesson.isLive || lesson.canPlay) &&
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

  VodLesson get _catalogSelection =>
      _catalog
          .where((lesson) =>
              lesson.id == _lesson.id && lesson.isLive == _lesson.isLive)
          .firstOrNull ??
      _lesson;

  String? get _activeClassroom {
    final classrooms = _classrooms;
    if (classrooms.contains(_selectedClassroom)) return _selectedClassroom;
    final current = _catalogSelection.classroom.trim();
    return classrooms.contains(current) ? current : classrooms.firstOrNull;
  }

  List<VodLesson> get _filteredLessons {
    final classroom = _activeClassroom;
    return _lessons
        .where((lesson) => lesson.classroom.trim() == classroom)
        .toList(growable: false);
  }

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
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPlayerPreferences());
    if (_isMobile) _systemUi.lockPortrait();
    var initial = widget.initialLesson ?? widget.course.liveLesson;
    if (widget.skipInitialCatalogLoad &&
        (initial == null ||
            !initial.canPlay ||
            initial.id <= 0 ||
            initial.teachingClassId != widget.course.teachingClassId)) {
      final candidates = _lessons.where((lesson) => lesson.id > 0).toList();
      initial =
          candidates.where((lesson) => lesson.isLiveAvailable).firstOrNull ??
              candidates
                  .where((lesson) => !lesson.isLive && lesson.isPlayable)
                  .firstOrNull ??
              candidates.where((lesson) => lesson.canPlay).firstOrNull;
    }
    if (initial != null &&
        initial.canPlay &&
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
        unawaited(_loadCatalog());
      }
    } else if (widget.skipInitialCatalogLoad) {
      _loading = false;
    } else {
      unawaited(widget.repository == null || !_shouldLoadCatalog
          ? _loadLesson(_lesson)
          : _loadCatalog());
    }
  }

  Future<void> _loadCatalog(
      {bool forceRefresh = false, bool fromPull = false}) async {
    final repository = widget.repository;
    if (repository == null ||
        !_shouldLoadCatalog ||
        _catalogLoading ||
        _catalogPullRefreshing) {
      return;
    }
    final revision = ++_catalogRevision;
    _publish(() {
      _catalogLoading = true;
      _catalogPullRefreshing = fromPull;
    });
    try {
      final lessons = widget.loadPreviewCatalog
          ? await repository.loadAndWarmSearchLessons(
              widget.course,
              [
                ...widget.lessons,
                if (_lesson.id > 0) _lesson,
              ],
              forceRefresh: forceRefresh)
          : await repository.loadCourseLessons(widget.course,
              forceRefresh: forceRefresh);
      if (!mounted || revision != _catalogRevision) return;
      _publish(() {
        if (widget.loadPreviewCatalog) {
          // Keep search results and the current selection even when the
          // preview omits them. A response must never switch playback.
          final merged = <(int, bool), VodLesson>{
            for (final lesson in widget.lessons)
              (lesson.id, lesson.isLive): lesson,
            if (_lesson.id > 0) (_lesson.id, _lesson.isLive): _catalogSelection,
            for (final lesson in lessons) (lesson.id, lesson.isLive): lesson,
          };
          _catalog = merged.values.toList();
        } else {
          _catalog = _loading &&
                  _lesson.canPlay &&
                  !lessons.any((lesson) =>
                      lesson.id == _lesson.id &&
                      lesson.isLive == _lesson.isLive)
              ? [_lesson, ...lessons]
              : lessons;
        }
        _catalogLoading = false;
      });
      // Preview refreshes must not interrupt an existing playback. A course
      // opened without an initial lesson still needs its first selection.
      if (widget.loadPreviewCatalog && _validLesson(_lesson)) return;
      final ordered = _lessons;
      final current = ordered
          .where((lesson) =>
              lesson.id == _lesson.id &&
              lesson.isLive == _lesson.isLive &&
              lesson.canPlay)
          .firstOrNull;
      final selected = current ??
          ordered.where((lesson) => lesson.isLiveAvailable).firstOrNull ??
          ordered
              .where((lesson) => !lesson.isLive && lesson.isPlayable)
              .firstOrNull ??
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
      if (widget.loadPreviewCatalog && _validLesson(_lesson) ||
          ((_playback != null || _loading && _lesson.canPlay) &&
              error is! VodSessionExpiredException &&
              (error is! VodPermissionException || !_lesson.isLive))) {
        _publish(() => _catalogLoading = false);
        if (error is! VodPermissionException) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('选集刷新失败，请稍后下拉重试')));
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
          VodSessionExpiredException() => _PlaybackFailure.session,
          VodPermissionException() => _PlaybackFailure.permission,
          VodNetworkException() => _PlaybackFailure.network,
          _ => _PlaybackFailure.unavailable,
        };
      });
    } finally {
      if (mounted && revision == _catalogRevision && _catalogPullRefreshing) {
        _publish(() => _catalogPullRefreshing = false);
      }
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
    _episodeNavigationRevision++;
    _loadRevision++;
    _notesRevision++;
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
    _tabController.dispose();
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

  Future<void> _loadNotes(VodLesson lesson, {bool forceRefresh = false}) async {
    if (!forceRefresh && _notesLessonId == lesson.id) return;
    final revision = ++_notesRevision;
    final repository = widget.repository;
    final pullRefresh =
        forceRefresh && _notesLessonId == lesson.id && !_notesLoading;
    final supported = lesson.id > 0 &&
        !lesson.isLive &&
        lesson.teachingClassId == widget.course.teachingClassId;
    final canLoad =
        supported && (widget.loadNotes != null || repository != null);
    setState(() {
      _notesLessonId = lesson.id;
      if (!pullRefresh) {
        _notes = const [];
        _notesError = null;
        _notesLoading = canLoad;
      }
      if (!canLoad) {
        _notes = const [];
        _notesLoading = false;
        _notesError = lesson.isLive
            ? '直播课次暂不支持 PPT 笔记'
            : supported
                ? '暂时无法加载这节课的 PPT 笔记，请稍后下拉重试'
                : '请先选择课次，再查看 PPT 笔记';
      }
    });
    if (!canLoad) return;
    try {
      final slides = await (widget.loadNotes?.call(lesson.id) ??
          repository!.loadPptSlides(lesson.id, forceRefresh: forceRefresh));
      if (!mounted || revision != _notesRevision) return;
      setState(() {
        _notes = slides;
        _notesLoading = false;
        _notesError = null;
      });
    } on Object catch (error) {
      if (!mounted || revision != _notesRevision) return;
      final message = switch (error) {
        VodSessionExpiredException() => '校园账户登录已失效，请重新进入录播平台后重试',
        VodPermissionException() => '平台暂未允许读取这节课的 PPT 笔记，请稍后下拉重试',
        VodInvalidResponseException() => '平台返回的 PPT 笔记数据异常，请稍后下拉重试',
        _ => '暂时无法加载这节课的 PPT 笔记，请稍后下拉重试',
      };
      final keepNotes = pullRefresh && _notes.isNotEmpty;
      setState(() {
        _notesLoading = false;
        if (!keepNotes) _notesError = message;
      });
      if (keepNotes) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }

  Future<void> _loadLesson(VodLesson lesson, {bool resume = false}) async {
    final revision = ++_loadRevision;
    _viewAudioRevision++;
    _resetSeekSynchronization();
    _openingMediaRevision = null;
    _secondaryRevision++;
    _secondaryViewIndex = null;
    _secondaryLoading = false;
    _secondaryWaitingForMain = false;
    _pendingViewIndex = null;
    if (lesson.id != _lesson.id) _preferredView = '教室';
    _publish(() {
      _lesson = lesson;
      _loading = true;
      _failure = null;
      _failureMessage = null;
      _playback = null;
    });
    unawaited(_loadNotes(lesson));
    await _disposeRtc();
    if (!mounted || revision != _loadRevision) return;
    unawaited(_secondaryPlayer?.pause());
    _stopLiveTimers();
    final oldProxy = _liveProxy;
    _liveProxy = null;
    await oldProxy?.dispose();
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
        await _viewAudioQueue;
        if (!mounted || revision != _loadRevision) return;
        if (_viewVolumeInitialized) await player.setVolume(_viewVolume);
        if (!mounted || revision != _loadRevision) return;
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
    final timeline = _timelinePlayer;
    if (timedOut &&
        primary != null &&
        timeline != null &&
        !_seekAwaitingPosition.contains(primary) &&
        _seekAwaitingPosition.contains(timeline)) {
      _publish(() => _timelinePlayer = primary);
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
    var recoveredPreviewSession = false;
    if (_failure == _PlaybackFailure.session) {
      final recover = widget.onSessionExpired;
      if (recover == null) return;
      _publish(() {
        _recovering = true;
        if (widget.loadPreviewCatalog) {
          // A request issued under the old session may complete after login.
          _catalogRevision++;
          _catalogLoading = false;
          _catalogPullRefreshing = false;
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
      _notesLessonId = null;
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

  Future<void> _alignSecondary() async {
    if (_isWebRtc) return;
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
        !_loading;
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
      }
    } on Object {
      if (stillCurrent()) _publish(() => _secondaryFailed = true);
    } finally {
      _syncingSecondary = false;
      _secondarySyncCompletion = null;
      completion.complete();
      if (_secondarySyncPending) {
        _secondarySyncPending = false;
        unawaited(_alignSecondary());
      }
      final pending = _pendingViewIndex;
      if (pending != null) {
        unawaited(_selectView(pending));
      }
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
                final topInset = MediaQuery.viewPaddingOf(context).top;
                if (portrait) {
                  _portraitViewport = constraints.biggest;
                  _portraitMediaQuery = MediaQuery.of(context);
                }
                final portraitViewport = _portraitViewport;
                final portraitMediaQuery = _portraitMediaQuery;
                // PiliPlus keeps its MiniScaffold and tab view mounted behind
                // fullscreen. Retain this entire tree too: keeping just offsets
                // would still lose an open detail panel and its text position.
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
      body: TabBarView(
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
              child: RecordingNotesPanel(
                key: ValueKey('recording-notes:${_lesson.id}'),
                nested: true,
                slides: _notes,
                loading:
                    _notesLoading || _notesLessonId == null && _catalogLoading,
                error:
                    _notesLessonId == null ? '请先选择课次，再查看 PPT 笔记' : _notesError,
                canSeek: !_loading &&
                    _failure == null &&
                    _playback != null &&
                    !_lesson.isLive,
                onRefresh: () => _loadNotes(_lesson, forceRefresh: true),
                onSeek: (position) {
                  if (!_loading &&
                      _failure == null &&
                      _playback != null &&
                      !_lesson.isLive) {
                    unawaited(_seekPlayers(position));
                  }
                },
                headersLoader: widget.repository?.mediaHeadersFor,
              )),
        ],
      ),
      expandedHeight: videoHeight,
      topInset: topInset,
      player: _lesson.isLive ? _player : _timelinePlayer ?? _player,
      playingOverride: _isWebRtc ? _rtcPlaying : null,
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

  PreferredSizeWidget _portraitTabs() => RecordingPlayerTabs(
        controller: _tabController,
        noteCount: _notes.isNotEmpty
            ? _notes.length
            : !_notesLoading &&
                    _notesError == null &&
                    _notesLessonId == _lesson.id
                ? 0
                : null,
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
    final session = _failure == _PlaybackFailure.session;
    final message = _failureMessage ??
        switch (_failure) {
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
    final days = recordingCourseDays(_filteredLessons);
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
    final episodeKeys = nested ? _episodeKeys : _landscapeEpisodeKeys;
    final headingKey =
        nested ? _episodeHeadingKey : _landscapeEpisodeHeadingKey;
    final chronological = _lessons;
    final filtered = _filteredLessons;
    final lessons = _episodesNewestFirst
        ? filtered
        : filtered.reversed.toList(growable: false);
    final episodeNumbers = {
      for (var index = 0; index < filtered.length; index++)
        filtered[index].id: filtered.length - index,
    };
    final months = <(int, int)?, List<VodLesson>>{};
    for (final lesson in lessons) {
      final date = lesson.beginTime;
      final month = date == null ? null : (date.year, date.month);
      months.putIfAbsent(month, () => []).add(lesson);
    }
    final content = CustomScrollView(
      key: const ValueKey('course-player-episodes'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (nested)
          SliverLayoutBuilder(
              builder: (context, constraints) => SliverOverlapInjector(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                      context))),
        if (_catalogLoading && !_catalogPullRefreshing)
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
        for (final month in months.entries)
          SliverMainAxisGroup(
            key: ValueKey('recording-episode-month-group:${month.key}'),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _EpisodeMonthHeader(month: month.key),
              ),
              SliverList.builder(
                itemCount: month.value.length,
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<int>) return null;
                  final index = month.value
                      .indexWhere((lesson) => lesson.id == key.value);
                  return index < 0 ? null : index;
                },
                itemBuilder: (context, index) {
                  final lesson = month.value[index];
                  return KeyedSubtree(
                    key: ValueKey(lesson.id),
                    child: Column(
                      key: episodeKeys.putIfAbsent(lesson.id, GlobalKey.new),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RecordingEpisodeTile(
                          tileKey: ValueKey('recording-lesson-${lesson.id}'),
                          lesson: lesson,
                          number: episodeNumbers[lesson.id]!,
                          selected: lesson.id == _lesson.id,
                          onTap: !lesson.canPlay || lesson.id == _lesson.id
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
    return widget.repository == null || !_shouldLoadCatalog
        ? content
        : RefreshIndicator(
            notificationPredicate: (notification) =>
                (!_catalogLoading || _catalogPullRefreshing) &&
                defaultScrollNotificationPredicate(notification),
            onRefresh: () => _loadCatalog(forceRefresh: true, fromPull: true),
            child: content,
          );
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
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final nestedController = PrimaryScrollController.of(context);
    return AnimatedBuilder(
      animation: widget.controller,
      child: KeyedSubtree(
        key: PageStorageKey(
            ('recording-player-tab', widget.index, widget.scrollIdentity)),
        child: widget.child,
      ),
      builder: (context, child) {
        // NestedScrollView forwards a drag to every attached inner position.
        // An inactive kept-alive tab must retain its own position without also
        // receiving the visible tab's scroll deltas.
        return widget.controller.index == widget.index
            ? PrimaryScrollController(
                controller: nestedController,
                child: child!,
              )
            : PrimaryScrollController.none(child: child!);
      },
    );
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
