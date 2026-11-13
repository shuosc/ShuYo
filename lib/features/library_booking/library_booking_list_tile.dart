import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../shared/theme/shuyo_theme.dart';

class LibraryBookingListTile extends StatefulWidget {
  const LibraryBookingListTile({
    super.key,
    required this.index,
    required this.title,
    required this.venueName,
    required this.status,
    required this.timeRange,
    required this.onTap,
  });

  final int index;
  final String title;
  final String venueName;
  final String status;
  final String timeRange;
  final VoidCallback? onTap;

  @override
  State<LibraryBookingListTile> createState() => _LibraryBookingListTileState();
}

class _LibraryBookingListTileState extends State<LibraryBookingListTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  Timer? _entranceTimer;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _entranceTimer = Timer(
      Duration(milliseconds: (widget.index % 6) * 55),
      () {
        if (mounted) _entrance.forward();
      },
    );
  }

  @override
  void dispose() {
    _entranceTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final highlightedStatus = widget.status == '待履约' || widget.status == '进行中';
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
      child: FadeTransition(
        opacity: _entrance,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 7),
                      Text(widget.venueName,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.textTertiary)),
                      const SizedBox(height: 8),
                      Text(widget.timeRange,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.textMuted)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: widget.onTap == null ? 64 : 88,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          widget.status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: highlightedStatus
                                    ? colors.accent
                                    : colors.textSecondary,
                                fontWeight:
                                    highlightedStatus ? FontWeight.w600 : null,
                              ),
                        ),
                      ),
                      if (widget.onTap != null) ...[
                        const SizedBox(width: 2),
                        Icon(Icons.chevron_right,
                            color: highlightedStatus
                                ? colors.accent
                                : colors.textMuted),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
