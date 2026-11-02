import 'package:flutter/material.dart';

class RecordingClassroomFilter extends StatelessWidget {
  const RecordingClassroomFilter({
    super.key,
    required this.classrooms,
    required this.selected,
    required this.onChanged,
  });

  final List<String> classrooms;
  final String? selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (classrooms.length < 2) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        key: const ValueKey('recording-classroom-filter'),
        height: 50,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: classrooms.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final room = classrooms[index];
            return Center(
              child: ChoiceChip(
                key: ValueKey('recording-classroom:$room'),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 96),
                  child: Text(room.isEmpty ? '教室未知' : room,
                      textAlign: TextAlign.left),
                ),
                selected: selected == room,
                onSelected: (_) => onChanged(room),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                showCheckmark: false,
                labelStyle: TextStyle(fontSize: 12, color: colors.onSurface),
              ),
            );
          },
        ),
      ),
    );
  }
}
