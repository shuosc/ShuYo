import 'dart:async';

import 'package:material_ui/material_ui.dart';

Future<bool> showInfoConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确认',
  String? secondaryText,
  Duration confirmDelay = Duration.zero,
  bool barrierDismissible = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) {
      return _InfoConfirmDialog(
        title: title,
        message: message,
        confirmText: confirmText,
        secondaryText: secondaryText,
        confirmDelay: confirmDelay,
      );
    },
  );
  return confirmed ?? false;
}

class _InfoConfirmDialog extends StatefulWidget {
  const _InfoConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmText,
    required this.secondaryText,
    required this.confirmDelay,
  });

  final String title;
  final String message;
  final String confirmText;
  final String? secondaryText;
  final Duration confirmDelay;

  @override
  State<_InfoConfirmDialog> createState() => _InfoConfirmDialogState();
}

class _InfoConfirmDialogState extends State<_InfoConfirmDialog> {
  Timer? _timer;
  late int _remainingSeconds;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = _secondsFor(widget.confirmDelay);
    if (_remainingSeconds > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _remainingSeconds -= 1;
          if (_remainingSeconds <= 0) {
            _timer?.cancel();
            _timer = null;
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = _remainingSeconds <= 0;
    final label = canConfirm
        ? widget.confirmText
        : '${widget.confirmText}（$_remainingSeconds）';

    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Text(widget.message),
      ),
      actions: [
        if (widget.secondaryText != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.secondaryText!),
          ),
        FilledButton(
          onPressed: canConfirm ? () => Navigator.of(context).pop(true) : null,
          child: Text(label),
        ),
      ],
    );
  }

  int _secondsFor(Duration duration) {
    if (duration <= Duration.zero) {
      return 0;
    }
    return (duration.inMilliseconds + 999) ~/ 1000;
  }
}
