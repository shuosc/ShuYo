import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/course_recording.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'recording_playback_info.dart';
import 'recording_player_preferences.dart';

enum _PlayerMenuAction { settings, information, links }

Future<void> showRecordingPlayerMenu({
  required BuildContext context,
  required bool fullscreen,
  required RecordingPlayerPreferences preferences,
  required ValueChanged<RecordingPlayerPreferences>? onPreferencesChanged,
  required bool secondaryAvailable,
  required List<VodView> views,
  required Future<List<RecordingPlaybackInfoEntry>> Function()
      informationLoader,
}) async {
  final itemStyle = fullscreen ? const TextStyle(fontSize: 14) : null;
  final action = await _showPanel<_PlayerMenuAction>(
    context,
    fullscreen: fullscreen,
    builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        dense: fullscreen,
        leading: const Icon(Icons.settings_outlined, size: 20),
        title: Text('播放设置', style: itemStyle),
        onTap: () => Navigator.of(context).pop(_PlayerMenuAction.settings),
      ),
      ListTile(
        dense: fullscreen,
        leading: const Icon(Icons.info_outline, size: 20),
        title: Text('播放信息', style: itemStyle),
        onTap: () => Navigator.of(context).pop(_PlayerMenuAction.information),
      ),
      ListTile(
        dense: fullscreen,
        leading: const Icon(Icons.link, size: 20),
        title: Text('播放链接', style: itemStyle),
        onTap: () => Navigator.of(context).pop(_PlayerMenuAction.links),
      ),
    ]),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case _PlayerMenuAction.settings:
      var current = preferences;
      await _showPanel<void>(context, fullscreen: fullscreen,
          builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          void update(RecordingPlayerPreferences next) {
            setState(() => current = next);
            onPreferencesChanged?.call(next);
          }

          return Column(mainAxisSize: MainAxisSize.min, children: [
            _panelHeading(context, '播放设置', fullscreen),
            SwitchListTile(
              dense: fullscreen,
              title: Text('显示现实时间', style: itemStyle),
              value: current.showClock,
              onChanged: onPreferencesChanged == null
                  ? null
                  : (value) => update(current.copyWith(showClock: value)),
            ),
            SwitchListTile(
              dense: fullscreen,
              title: Text('第二视角浮窗', style: itemStyle),
              value: current.secondaryView,
              onChanged: onPreferencesChanged == null || !secondaryAvailable
                  ? null
                  : (value) => update(current.copyWith(secondaryView: value)),
            ),
            if (!fullscreen)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('完成'),
                    )),
              ),
          ]);
        });
      });
    case _PlayerMenuAction.information:
      final future = informationLoader();
      Widget information(BuildContext context) =>
          FutureBuilder<List<RecordingPlaybackInfoEntry>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 3)));
              }
              if (!snapshot.hasData) {
                return const Padding(
                    padding: EdgeInsets.all(24), child: Text('暂时无法读取播放信息'));
              }
              return Column(mainAxisSize: MainAxisSize.min, children: [
                for (final entry in snapshot.data!)
                  ListTile(
                    dense: true,
                    title: Text(entry.title),
                    subtitle: Text(entry.value),
                    onTap: () =>
                        _copy(context, '${entry.title}\n${entry.value}'),
                  ),
              ]);
            },
          );
      if (fullscreen) {
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('播放信息'),
                  contentPadding: const EdgeInsets.only(top: 16),
                  content: Material(
                      type: MaterialType.transparency,
                      child: ListTileTheme(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 24),
                          child: SingleChildScrollView(
                              child: information(context)))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('确定'))
                  ],
                ));
      } else {
        await _showPanel<void>(context,
            fullscreen: false,
            builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _panelHeading(context, '播放信息', false),
                    information(context)
                  ],
                ));
      }
    case _PlayerMenuAction.links:
      await _showPanel<void>(context,
          fullscreen: fullscreen,
          builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _panelHeading(context, '播放链接', fullscreen),
                  if (views.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(24), child: Text('暂无可用的播放链接')),
                  for (final view in views) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Center(
                          child: Text(view.label,
                              style: TextStyle(
                                  color: context.shuyoColors.textPrimary,
                                  fontSize: fullscreen ? 14 : 16,
                                  fontWeight: FontWeight.w600))),
                    ),
                    ListTile(
                      key: ValueKey(
                          'recording-playback-link-${view.viewNumber}'),
                      dense: fullscreen,
                      title: Text(view.url.toString(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: context.shuyoColors.textSecondary)),
                      trailing: const Icon(Icons.copy_outlined, size: 20),
                      onTap: () => _copy(context, view.url.toString()),
                    ),
                  ],
                  Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                          views.any((view) => view.webRtcSource != null)
                              ? 'WebRTC 音视频通过会话传输，没有独立直链。点击可复制对应信令链接。'
                              : '点击链接即可复制。',
                          style: TextStyle(
                              fontSize: 12,
                              color: context.shuyoColors.textSecondary))),
                ],
              ));
  }
}

Widget _panelHeading(BuildContext context, String title, bool fullscreen) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(children: [
        Expanded(
            child: Text(title,
                style: TextStyle(
                    color: context.shuyoColors.textPrimary,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w600))),
        if (fullscreen)
          IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop()),
      ]),
    );

Future<void> _copy(BuildContext context, String value) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('已复制')));
  }
}

Future<T?> _showPanel<T>(
  BuildContext context, {
  required bool fullscreen,
  required WidgetBuilder builder,
}) {
  if (!fullscreen) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final bottom = MediaQuery.viewPaddingOf(context).bottom;
        return SafeArea(
          top: false,
          bottom: false,
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .7),
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottom),
            decoration: BoxDecoration(
                color: context.shuyoColors.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8))),
            child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(child: builder(context))),
          ),
        );
      },
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: math.min(512, MediaQuery.sizeOf(context).width * .5),
          height: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              color: context.shuyoColors.surface,
              clipBehavior: Clip.hardEdge,
              borderRadius: BorderRadius.circular(12),
              child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: builder(context)),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                .animate(CurvedAnimation(
                    parent: animation, curve: Curves.easeInOut)),
            child: child),
  );
}
