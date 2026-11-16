import 'dart:async';

const recordingSeekPositionTimeout = Duration(seconds: 8);
const _seekPositionTolerance = Duration(seconds: 1);

bool recordingSeekPositionMatches(Duration position, Duration target) =>
    (position - target).abs() <= _seekPositionTolerance;

class RecordingSeekController {
  RecordingSeekController({
    required Future<void> Function(Duration position) seek,
    this.previewInterval = const Duration(milliseconds: 90),
    this.onPreviewError,
  }) : _seek = seek;

  final Future<void> Function(Duration position) _seek;
  final Duration previewInterval;
  final void Function(Object error, StackTrace stack)? onPreviewError;
  Timer? _timer;
  _SeekRequest? _pending;
  bool _running = false;
  bool _disposed = false;

  void begin() {
    if (_disposed) return;
    _clearPending();
  }

  void preview(Duration position) {
    if (_disposed) return;
    _replacePending(_SeekRequest(position));
    _flush();
  }

  Future<void> finish(Duration position) {
    if (_disposed) return Future<void>.value();
    final completion = Completer<void>();
    _replacePending(_SeekRequest(position, completion: completion));
    _timer?.cancel();
    _timer = null;
    _flush();
    return completion.future;
  }

  void dispose() {
    _disposed = true;
    _clearPending();
  }

  void _replacePending(_SeekRequest request) {
    _pending?.completion?.complete();
    _pending = request;
  }

  void _clearPending() {
    _timer?.cancel();
    _timer = null;
    _pending?.completion?.complete();
    _pending = null;
  }

  void _flush() {
    if (_disposed || _running || _pending == null) return;
    final request = _pending!;
    if (request.completion == null && _timer != null) return;
    _timer?.cancel();
    _timer = request.completion == null
        ? Timer(previewInterval, () {
            _timer = null;
            _flush();
          })
        : null;
    _pending = null;
    _running = true;
    unawaited(_run(request));
  }

  Future<void> _run(_SeekRequest request) async {
    try {
      await _seek(request.position);
      request.completion?.complete();
    } catch (error, stack) {
      final completion = request.completion;
      if (completion != null) {
        completion.completeError(error, stack);
      } else {
        onPreviewError?.call(error, stack);
      }
    } finally {
      _running = false;
      _flush();
    }
  }
}

class _SeekRequest {
  _SeekRequest(this.position, {this.completion});

  final Duration position;
  final Completer<void>? completion;
}
