import 'package:flutter/material.dart';

class RecordingClassroomFilter extends StatelessWidget {
  const RecordingClassroomFilter({
    super.key,
    required this.classrooms,
    required this.excluded,
    required this.onChanged,
  });

  final List<String> classrooms;
  final Set<String> excluded;
  final void Function(String classroom, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    if (classrooms.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        key: const ValueKey('recording-classroom-filter'),
        height: 50,
        child: Row(children: [
          const SizedBox(width: 14),
          Text('教室', style: TextStyle(fontSize: 16, color: colors.onSurface)),
          const SizedBox(width: 10),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 14),
              itemCount: classrooms.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final room = classrooms[index];
                final selected =
                    classrooms.length == 1 || !excluded.contains(room);
                return Center(
                  child: FilterChip(
                    key: ValueKey('recording-classroom:$room'),
                    label: Text(room.isEmpty ? '教室未知' : room),
                    selected: selected,
                    onSelected: classrooms.length == 1
                        ? null
                        : (value) => onChanged(room, value),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    showCheckmark: true,
                    labelStyle:
                        TextStyle(fontSize: 12, color: colors.onSurface),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
