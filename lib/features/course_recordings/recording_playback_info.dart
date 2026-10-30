import 'package:media_kit/media_kit.dart';

import '../../data/models/course_recording.dart';

typedef RecordingPlaybackInfoEntry = ({String title, String value});

Future<List<RecordingPlaybackInfoEntry>> readRecordingPlaybackInfo(
  Player player, {
  required VodView? view,
}) async {
  final state = player.state;
  final platform = player.platform;
  var hwdec = '不可用';
  if (platform is NativePlayer) {
    try {
      hwdec = await platform
          .getProperty('hwdec-current')
          .timeout(const Duration(seconds: 2));
      if (hwdec.isEmpty) hwdec = '不可用';
    } on Object {
      hwdec = '不可用';
    }
  }
  return [
    (
      title: 'Resolution',
      value: state.width != null && state.height != null
          ? '${state.width}x${state.height}'
          : '不可用'
    ),
    (title: 'VideoParams', value: state.videoParams.toString()),
    (title: 'AudioParams', value: state.audioParams.toString()),
    (title: 'Media', value: view?.url.toString() ?? '不可用'),
    (title: 'AudioTrack', value: state.track.audio.toString()),
    (title: 'VideoTrack', value: state.track.video.toString()),
    (title: 'rate', value: state.rate.toString()),
    (title: 'Volume', value: state.volume.toString()),
    (title: 'hwdec', value: hwdec),
  ];
}
