import 'package:flutter/material.dart';

class RecordingPlaybackLoading extends StatelessWidget {
  const RecordingPlaybackLoading({
    super.key,
    this.buffering = false,
    this.buffered = Duration.zero,
    this.onRetry,
    this.compact = false,
  });

  final bool buffering;
  final Duration buffered;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final seconds = buffered.inSeconds;
    final label = seconds <= 0 ? '加载中...' : _formatDuration(seconds);
    return Center(
      child: Semantics(
        label: buffering && seconds > 0 ? '已缓冲至 $label' : '正在加载',
        button: onRetry != null,
        child: GestureDetector(
          key: const ValueKey('recording-loading-indicator'),
          behavior: HitTestBehavior.opaque,
          onTap: onRetry,
          child: Container(
            padding: EdgeInsets.all(compact ? 6 : 20),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Colors.black26, Colors.transparent],
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset(
                'assets/images/recording_player_loading.webp',
                width: compact ? 20 : 25,
                height: compact ? 20 : 25,
                color: Colors.white,
                excludeFromSemantics: true,
              ),
              if (buffering && !compact)
                Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$remainder' : '$minutes:$remainder';
  }
}

class RecordingPlaybackMessage extends StatelessWidget {
  const RecordingPlaybackMessage({
    super.key,
    required this.message,
    required this.icon,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white70, size: 25),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
            if (action != null) action!,
          ]),
        ),
      );
}
