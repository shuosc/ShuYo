part of 'empty_classroom_page.dart';

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.options,
    required this.selectedCampus,
    required this.selectedBuilding,
    required this.selectedDate,
    required this.selectedSections,
    required this.fixedDate,
    required this.onCampusChanged,
    required this.onBuildingChanged,
    required this.onPickDate,
    required this.onPickSections,
  });

  final ClassroomSearchOptions options;
  final String? selectedCampus;
  final ClassroomBuilding? selectedBuilding;
  final DateTime selectedDate;
  final Set<int> selectedSections;
  final bool fixedDate;
  final ValueChanged<String?> onCampusChanged;
  final ValueChanged<ClassroomBuilding?> onBuildingChanged;
  final VoidCallback onPickDate;
  final VoidCallback onPickSections;

  @override
  Widget build(BuildContext context) {
    final buildings = options.buildings
        .where(
          (building) =>
              selectedCampus == null || building.campusName == selectedCampus,
        )
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        children: [
          _ControlPair(
            first: DropdownButtonFormField<String>(
              key: ValueKey('campus-$selectedCampus'),
              initialValue: selectedCampus,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '校区', isDense: true),
              items: [
                for (final campus in options.campusNames)
                  DropdownMenuItem(value: campus, child: Text(campus)),
              ],
              onChanged: onCampusChanged,
            ),
            second: DropdownButtonFormField<int>(
              key: ValueKey('building-$selectedCampus-${selectedBuilding?.id}'),
              initialValue: selectedBuilding?.id ?? 0,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: '教学楼', isDense: true),
              items: [
                const DropdownMenuItem(value: 0, child: Text('全部教学楼')),
                for (final building in buildings)
                  DropdownMenuItem(
                    value: building.id,
                    child: Text(building.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) =>
                  onBuildingChanged(_buildingById(buildings, id)),
            ),
          ),
          const SizedBox(height: 6),
          _ControlPair(
            first: fixedDate
                ? Center(child: Text(_dateLabel(selectedDate)))
                : OutlinedButton.icon(
                    key: const ValueKey('classroom-date'),
                    onPressed: onPickDate,
                    icon: const Icon(Icons.calendar_today_outlined, size: 17),
                    label: Text(_dateLabel(selectedDate)),
                  ),
            second: OutlinedButton.icon(
              key: const ValueKey('classroom-sections'),
              onPressed: onPickSections,
              icon: const Icon(Icons.schedule, size: 18),
              label: Text(_sectionLabel(selectedSections),
                  textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlPair extends StatelessWidget {
  const _ControlPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          if (constraints.maxWidth < 264 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [first, const SizedBox(height: 8), second],
            );
          }
          return Row(children: [
            Expanded(child: first),
            const SizedBox(width: 8),
            Expanded(child: second),
          ]);
        },
      );
}

enum _SectionGranularity { blocks, single }

class _SectionPickerSheet extends StatefulWidget {
  const _SectionPickerSheet({
    required this.ranges,
    required this.sections,
    required this.selected,
  });

  final List<ClassroomSectionRange> ranges;
  final List<ClassroomSection> sections;
  final Set<int> selected;

  @override
  State<_SectionPickerSheet> createState() => _SectionPickerSheetState();
}

class _SectionPickerSheetState extends State<_SectionPickerSheet> {
  late final _selected = {...widget.selected};
  late var _granularity = widget.ranges.any((range) {
    final numbers = range.sections;
    return numbers.any(_selected.contains) &&
        !numbers.every(_selected.contains);
  })
      ? _SectionGranularity.single
      : _SectionGranularity.blocks;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final timeBySection = {
      for (final section in widget.sections) section.index: section
    };
    final ranges = _granularity == _SectionGranularity.blocks
        ? widget.ranges
        : [
            for (final range in widget.ranges)
              for (final number in range.sections)
                ClassroomSectionRange(start: number, end: number),
          ];
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text('节次', style: ShuYoTextStyles.pageTitle())),
            TextButton(
              onPressed:
                  _selected.isEmpty ? null : () => setState(_selected.clear),
              child: const Text('清空'),
            ),
          ]),
          _ClassroomSegments(
            segments: const [
              ButtonSegment(
                  value: _SectionGranularity.blocks, label: Text('时段')),
              ButtonSegment(
                  value: _SectionGranularity.single, label: Text('单节')),
            ],
            selected: _granularity,
            onChanged: (value) => setState(() => _granularity = value),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: LayoutBuilder(builder: (context, constraints) {
                const gap = 8.0;
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final columns =
                    ((constraints.maxWidth + gap) / (136 * scale + gap))
                        .floor()
                        .clamp(1, 3);
                final width =
                    (constraints.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  spacing: gap,
                  children: [
                    for (final range in ranges)
                      SizedBox(
                          width: width,
                          child: _slot(range, timeBySection, colors)),
                  ],
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(_selected),
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }

  Widget _slot(ClassroomSectionRange range, Map<int, ClassroomSection> times,
      ShuYoColors colors) {
    final numbers = range.sections;
    final selected = numbers.every(_selected.contains);
    final partial = !selected && numbers.any(_selected.contains);
    final start = times[range.start]?.startTime ?? '';
    final end = times[range.end]?.endTime ?? '';
    return Semantics(
      value: partial ? '部分已选' : null,
      child: FilterChip(
        key: ValueKey('classroom-slot-${range.start}-${range.end}'),
        selected: selected,
        selectedColor: colors.accentSoft,
        checkmarkColor: colors.onAccentSoft,
        side: BorderSide(
            color: selected || partial ? colors.accent : colors.borderStrong),
        avatar:
            partial ? Icon(Icons.remove, color: colors.accent, size: 18) : null,
        label: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(range.label,
                style: TextStyle(
                    color:
                        selected ? colors.onAccentSoft : colors.textPrimary)),
            if (start.isNotEmpty && end.isNotEmpty)
              Text('$start–$end',
                  style: ShuYoTextStyles.bodyCompact(
                      color: colors.textSecondary, size: 12)),
          ],
        ),
        onSelected: (_) => setState(() {
          selected ? _selected.removeAll(numbers) : _selected.addAll(numbers);
        }),
      ),
    );
  }
}

class _ClassroomSegments<T> extends StatelessWidget {
  const _ClassroomSegments({
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return SegmentedButton<T>(
      segments: segments,
      selected: {selected},
      onSelectionChanged: (values) => onChanged(values.single),
      showSelectedIcon: false,
      expandedInsets: EdgeInsets.zero,
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        side: WidgetStatePropertyAll(BorderSide(color: colors.borderStrong)),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? colors.accentSoft
                : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? colors.onAccentSoft
                : colors.textSecondary),
      ),
    );
  }
}

String _sectionLabel(Set<int> sections) {
  final sorted = sections.toList()..sort();
  final labels = <String>[];
  for (var i = 0; i < sorted.length; i++) {
    final start = sorted[i];
    while (i + 1 < sorted.length && sorted[i + 1] == sorted[i] + 1) {
      i++;
    }
    labels.add(start == sorted[i] ? '$start' : '$start–${sorted[i]}');
  }
  return labels.isEmpty ? '节次' : '${labels.join('、')}节';
}
