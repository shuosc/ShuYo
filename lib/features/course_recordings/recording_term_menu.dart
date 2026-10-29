import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models/course_recording.dart';

Future<int?> showRecordingTermMenu(
  BuildContext context, {
  required List<VodTerm> terms,
  required int? selectedTermId,
  Set<String> collapsedYears = const {},
  void Function(String year, bool expanded)? onExpansionChanged,
}) {
  return showGeneralDialog<int>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭学期菜单',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.18, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        )),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
    pageBuilder: (menuContext, animation, secondaryAnimation) => SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: kToolbarHeight + 8, right: 12),
          child: _RecordingTermMenu(
            terms: terms,
            selectedTermId: selectedTermId,
            initialCollapsedYears: collapsedYears,
            onExpansionChanged: onExpansionChanged,
            onSelect: (termId) => Navigator.of(menuContext).pop(termId),
          ),
        ),
      ),
    ),
  );
}

class _RecordingTermMenu extends StatefulWidget {
  const _RecordingTermMenu({
    required this.terms,
    required this.selectedTermId,
    required this.onSelect,
    required this.initialCollapsedYears,
    this.onExpansionChanged,
  });

  final List<VodTerm> terms;
  final int? selectedTermId;
  final ValueChanged<int> onSelect;
  final Set<String> initialCollapsedYears;
  final void Function(String year, bool expanded)? onExpansionChanged;

  @override
  State<_RecordingTermMenu> createState() => _RecordingTermMenuState();
}

class _RecordingTermMenuState extends State<_RecordingTermMenu> {
  final _scrollController = ScrollController();
  late final _collapsedYears = {...widget.initialCollapsedYears};

  void _toggleYear(String year) {
    setState(() {
      if (!_collapsedYears.add(year)) _collapsedYears.remove(year);
    });
    widget.onExpansionChanged?.call(year, !_collapsedYears.contains(year));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<VodTerm>>{};
    for (final term in widget.terms) {
      groups.putIfAbsent(term.academicYear, () => []).add(term);
    }
    final years = groups.keys.toList()
      ..sort((first, second) => second.compareTo(first));
    for (final terms in groups.values) {
      terms.sort(
          (first, second) => second.termNumber.compareTo(first.termNumber));
    }
    final surface = Theme.of(context).colorScheme.surface;
    return SizedBox(
      key: const ValueKey('vod-term-menu'),
      width: math.min(264.0, MediaQuery.sizeOf(context).width * 0.68),
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: CustomScrollView(
              key: const ValueKey('vod-term-menu-scroll'),
              controller: _scrollController,
              shrinkWrap: true,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                for (final year in years)
                  SliverMainAxisGroup(slivers: [
                    PinnedHeaderSliver(
                      child: Material(
                        key: ValueKey('vod-term-year:$year'),
                        color: surface,
                        child: ListTile(
                          contentPadding:
                              const EdgeInsets.only(left: 16, right: 12),
                          title: Text(
                            groups[year]!.first.academicYearLabel,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          trailing: Icon(_collapsedYears.contains(year)
                              ? Icons.expand_more
                              : Icons.expand_less),
                          onTap: () => _toggleYear(year),
                        ),
                      ),
                    ),
                    if (!_collapsedYears.contains(year))
                      SliverList.list(children: [
                        for (final term in groups[year]!)
                          ListTile(
                            key: ValueKey('vod-term-option:${term.id}'),
                            contentPadding:
                                const EdgeInsets.only(left: 24, right: 12),
                            title: Text(term.seasonLabel),
                            selected: term.id == widget.selectedTermId,
                            trailing: term.id == widget.selectedTermId
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => widget.onSelect(term.id),
                          ),
                      ]),
                  ]),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
