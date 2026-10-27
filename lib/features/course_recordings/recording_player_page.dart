import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/models/course_recording.dart';
import '../../data/services/vod_api_client.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';

/// A route for generated, account-authorized recordings only.
///
/// Sources are requested again for every lesson change and retry. Signed URLs
/// stay in this route's memory and never become widget keys or stored history.
class RecordingPlayerPage extends StatefulWidget {
  const RecordingPlayerPage({
    super.key,
    required this.course,
    required this.lessons,
    required this.initialLesson,
    required this.loadPlayback,
    this.onSessionExpired,
  });

  final VodCourse course;
  final List<VodLesson> lessons;
  final VodLesson initialLesson;
  final Future<VodPlayback> Function(VodLesson) loadPlayback;
  final Future<bool> Function()? onSessionExpired;

  @override
  State<RecordingPlayerPage> createState() => _RecordingPlayerPageState();
}

enum _PlaybackFailure { session, permission, network, unavailable, media }

class _RecordingPlayerPageState extends State<RecordingPlayerPage> {
  final _videoKey = GlobalKey<VideoState>();
  final _controlsRevision = ValueNotifier(0);
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<String>? _errorSubscription;
  late VodLesson _lesson = widget.initialLesson;
  VodPlayback? _playback;
  int _viewIndex = 0;
  int? _loadedLessonId;
  int _loadRevision = 0;
  Future<void> _mediaQueue = Future<void>.value();
  bool _loading = true;
  bool _recovering = false;
  bool _softwareDecoding = false;
  bool _fullscreenActive = false;
  _PlaybackFailure? _failure;

  List<VodLesson> get _lessons => widget.lessons
      .where((lesson) =>
          lesson.isPlayable &&
          lesson.teachingClassId == widget.course.teachingClassId)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    unawaited(_loadLesson(_lesson));
  }

  @override
  void dispose() {
    _loadRevision++;
    if (_fullscreenActive) unawaited(_exitFullscreen());
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
      lesson.isPlayable &&
      lesson.teachingClassId == widget.course.teachingClassId &&
      widget.lessons.any((item) => item.id == lesson.id && item.isPlayable);

  Future<void> _loadLesson(VodLesson lesson, {bool resume = false}) async {
    final revision = ++_loadRevision;
    final oldPosition =
        resume && _loadedLessonId == lesson.id ? _player?.state.position : null;
    _publish(() {
      _lesson = lesson;
      _loading = true;
      _failure = null;
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
      final playback = await widget.loadPlayback(lesson);
      if (!mounted || revision != _loadRevision) return;
      if (playback.lessonId != lesson.id ||
          playback.teachingClassId != widget.course.teachingClassId ||
          playback.views.isEmpty ||
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
      _publish(() {
        _playback = playback;
        _viewIndex = 0;
      });
      await _openView(
        0,
        revision: revision,
        position: oldPosition ?? playback.lastPosition,
      );
    } on Object catch (error) {
      if (!mounted || revision != _loadRevision) return;
      _publish(() {
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
          player = Player(
            configuration: const PlayerConfiguration(title: 'ShuYo 课程回放'),
          );
          _player = player;
          _videoController = VideoController(player);
          _errorSubscription = player.stream.error.listen((_) {
            if (mounted && !_loading) {
              _publish(() => _failure = _PlaybackFailure.media);
            }
          });
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
        await player.open(
          Media(
            view.url.toString(),
            httpHeaders: view.httpHeaders,
            start:
                position != null && position > Duration.zero ? position : null,
          ),
          play: play,
        );
        if (!mounted || revision != _loadRevision) return;
        if (rate != 1) await player.setRate(rate);
        _publish(() {
          _loadedLessonId = playback.lessonId;
          _loading = false;
        });
      } on Object {
        if (!mounted || revision != _loadRevision) return;
        if (!videoReady) {
          unawaited(_releasePlayer(_player, _errorSubscription));
          _player = null;
          _videoController = null;
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

  Future<void> _selectView(int index) async {
    if (index == _viewIndex || _loading) return;
    final revision = ++_loadRevision;
    await _openView(
      index,
      revision: revision,
      position: _player?.state.position,
      play: _player?.state.playing ?? true,
    );
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
    await _loadLesson(_lesson, resume: true);
  }

  Future<void> _toggleSoftwareDecoding() async {
    final player = _player;
    if (player == null || player.platform is! NativePlayer) return;
    try {
      final next = !_softwareDecoding;
      // Keep GPU rendering enabled while switching only the video decoder.
      // mpv selects a supported platform decoder in automatic mode.
      await (player.platform as NativePlayer)
          .setProperty('hwdec', next ? 'no' : 'auto-safe');
      _publish(() => _softwareDecoding = next);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂时无法切换解码方式，请重试。')),
      );
    }
  }

  Future<void> _enterFullscreen() async {
    _fullscreenActive = true;
    await defaultEnterNativeFullscreen();
  }

  Future<void> _exitFullscreen() async {
    _fullscreenActive = false;
    await defaultExitNativeFullscreen();
    if (!kIsWeb &&
        const [TargetPlatform.android, TargetPlatform.iOS]
            .contains(defaultTargetPlatform)) {
      // ShuYo does not impose an orientation lock. Restore that policy rather
      // than forcing portrait after leaving the player.
      await SystemChrome.setPreferredOrientations(const []);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: AppBar(title: const Text('课程回放')),
      body: LayoutBuilder(builder: (context, constraints) {
        final video = ColoredBox(
          color: Colors.black,
          child: _videoController == null
              ? AspectRatio(aspectRatio: 16 / 9, child: _placeholder())
              : Video(
                  key: _videoKey,
                  controller: _videoController!,
                  aspectRatio: 16 / 9,
                  onEnterFullscreen: _enterFullscreen,
                  onExitFullscreen: _exitFullscreen,
                  controls: (state) => ValueListenableBuilder<int>(
                    valueListenable: _controlsRevision,
                    builder: (context, _, __) => RecordingVideoControls(
                      state: state,
                      player: _player!,
                      title: widget.course.name,
                      loading: _loading,
                      failure: _failure == null ? null : _placeholder(),
                      views: _playback?.views ?? const [],
                      selectedView: _viewIndex,
                      onViewSelected: (index) => unawaited(_selectView(index)),
                      softwareDecoding: _softwareDecoding,
                      onDecodingChanged: !kIsWeb
                          ? () => unawaited(_toggleSoftwareDecoding())
                          : null,
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
                child: ListView(children: [video, _lessonHeading(colors)]),
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
      }),
    );
  }

  Widget _placeholder() {
    if (_loading || _recovering) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
      );
    }
    final session = _failure == _PlaybackFailure.session;
    final message = switch (_failure) {
      _PlaybackFailure.session => '校园账户登录已失效，请重新登录。',
      _PlaybackFailure.permission => '当前账号没有这节录播的观看权限。',
      _PlaybackFailure.network => '暂时无法连接录播平台，请检查网络后重试。',
      _PlaybackFailure.media => '视频暂时无法播放，可刷新播放地址后重试。',
      _ => '这节录播暂时无法观看，请稍后重试。',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.video_library_outlined, color: Colors.white70),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          if (!session || widget.onSessionExpired != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => unawaited(_retry()),
              icon: Icon(session ? Icons.login : Icons.refresh, size: 18),
              label: Text(session ? '重新登录' : '重试'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ]),
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
        Text(widget.course.name,
            style: ShuYoTextStyles.title(color: colors.textPrimary)),
        const SizedBox(height: 6),
        Text(meta, style: ShuYoTextStyles.meta(color: colors.textSecondary)),
        if ((_playback?.views.length ?? 0) > 1) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (var i = 0; i < _playback!.views.length; i++)
              ChoiceChip(
                label: Text(_playback!.views[i].label),
                selected: i == _viewIndex,
                onSelected: _loading ? null : (_) => unawaited(_selectView(i)),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _lessonList(ShuYoColors colors) {
    final lessons = _lessons;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _lessonHeading(colors),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('选集（${lessons.length}）',
              style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary)),
        ),
        for (var index = 0; index < lessons.length; index++)
          ListTile(
            key: ValueKey('recording-lesson-${lessons[index].id}'),
            selected: lessons[index].id == _lesson.id,
            selectedTileColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: .08),
            leading: Icon(lessons[index].id == _lesson.id
                ? Icons.play_circle_filled_rounded
                : Icons.play_circle_outline_rounded),
            title: Text('第 ${index + 1} 集 · ${_lessonDate(lessons[index])}',
                style: ShuYoTextStyles.bodyCompact()),
            subtitle: lessons[index].classroom.isEmpty
                ? null
                : Text(lessons[index].classroom, style: ShuYoTextStyles.meta()),
            trailing: lessons[index].id == _lesson.id
                ? Text('当前',
                    style: ShuYoTextStyles.meta(
                        color: Theme.of(context).colorScheme.primary))
                : null,
            onTap: lessons[index].id == _lesson.id
                ? null
                : () => unawaited(_loadLesson(lessons[index])),
          ),
      ],
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

/// Chinese controls shared by embedded and fullscreen recording playback.
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
  final VoidCallback? onDecodingChanged;

  @override
  State<RecordingVideoControls> createState() => _RecordingVideoControlsState();
}

class _RecordingVideoControlsState extends State<RecordingVideoControls> {
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _hideTimer;
  bool _visible = true;
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
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
    _hideTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _visible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && widget.player.state.playing && _dragPosition == null) {
        setState(() => _visible = false);
      }
    });
  }

  Future<void> _seekBy(int seconds) async {
    final state = widget.player.state;
    final position = (state.position + Duration(seconds: seconds))
        .inMilliseconds
        .clamp(0, math.max(0, state.duration.inMilliseconds));
    await widget.player.seek(Duration(milliseconds: position.toInt()));
    _showControls();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    final show = _visible || !state.playing || widget.loading;
    final fullscreen = widget.state.isFullscreen();
    return MouseRegion(
      onHover: (_) => _showControls(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => show ? setState(() => _visible = false) : _showControls(),
        onDoubleTap: widget.loading || widget.failure != null
            ? null
            : () => unawaited(widget.player.playOrPause()),
        child: Stack(children: [
          if (widget.failure != null) Positioned.fill(child: widget.failure!),
          if ((widget.loading || state.buffering) && widget.failure == null)
            const Center(
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 3),
            ),
          if (show) ...[
            if (fullscreen)
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    decoration: _gradient(top: true),
                    child: Row(children: [
                      IconButton(
                        tooltip: '退出全屏',
                        onPressed: () =>
                            unawaited(widget.state.exitFullscreen()),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ]),
                  ),
                ),
              ),
            if (widget.failure == null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  decoration: _gradient(),
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 4),
                  child: SafeArea(
                    top: false,
                    bottom: fullscreen,
                    child: _bottomControls(fullscreen),
                  ),
                ),
              ),
          ],
        ]),
      ),
    );
  }

  BoxDecoration _gradient({bool top = false}) => BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Color(0xB3000000), Colors.transparent],
        ),
      );

  Widget _bottomControls(bool fullscreen) {
    final state = widget.player.state;
    final duration = state.duration.inMilliseconds.toDouble();
    final position = (_dragPosition ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, math.max(1.0, duration));
    final time = Text(
      '${_durationText(state.position)} / ${_durationText(state.duration)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 11),
    );
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 480 ||
          (constraints.maxWidth < 650 &&
              MediaQuery.textScalerOf(context).scale(12) > 18);
      return IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 24,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: position.toDouble(),
                min: 0,
                max: math.max(1.0, duration),
                activeColor: Colors.white,
                inactiveColor: Colors.white38,
                label: _durationText(Duration(milliseconds: position.round())),
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
            ),
          ),
          if (compact)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(alignment: Alignment.centerLeft, child: time),
            ),
          Row(children: [
            IconButton(
              tooltip: state.playing ? '暂停' : '播放',
              onPressed: widget.loading
                  ? null
                  : () {
                      unawaited(widget.player.playOrPause());
                      _showControls();
                    },
              icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
            ),
            if (fullscreen && !compact) ...[
              IconButton(
                tooltip: '后退 10 秒',
                onPressed: () => unawaited(_seekBy(-10)),
                icon: const Icon(Icons.replay_10),
              ),
              IconButton(
                tooltip: '前进 10 秒',
                onPressed: () => unawaited(_seekBy(10)),
                icon: const Icon(Icons.forward_10),
              ),
            ],
            if (!compact) Flexible(child: time),
            const Spacer(),
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
                    child: Text('${rate == 1 ? '正常 ' : ''}${rate}x'),
                  ),
              ],
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                child: Text('${state.rate}x',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
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
                    child: Text(widget.views[index].label),
                  ),
                if (widget.onDecodingChanged != null) ...[
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(
                    value: -1,
                    checked: widget.softwareDecoding,
                    child: const Text('使用软件解码'),
                  ),
                ],
              ],
            ),
            IconButton(
              tooltip: fullscreen ? '退出全屏' : '全屏',
              onPressed: widget.loading
                  ? null
                  : () => unawaited(widget.state.toggleFullscreen()),
              icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            ),
          ]),
        ]),
      );
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
