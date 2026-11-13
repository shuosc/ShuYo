import 'package:material_ui/material_ui.dart';

import '../../data/models/home_layout.dart';
import '../../shared/theme/shuyo_theme.dart';

class HomeLayoutPage extends StatefulWidget {
  const HomeLayoutPage({
    super.key,
    required this.initialLayout,
    required this.onChanged,
  });

  final HomeLayout initialLayout;
  final Future<void> Function(HomeLayout) onChanged;

  @override
  State<HomeLayoutPage> createState() => _HomeLayoutPageState();
}

class _HomeLayoutPageState extends State<HomeLayoutPage> {
  late HomeLayout _layout = widget.initialLayout;
  late HomeLayout _savedLayout = widget.initialLayout;
  final _scrollController = ScrollController();
  Future<void> _saveTail = Future<void>.value();
  int _revision = 0;
  bool _saving = false;
  bool _saveFailed = false;
  bool _leaving = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _update(HomeLayout layout) {
    final revision = ++_revision;
    setState(() {
      _layout = layout;
      _saving = true;
      _saveFailed = false;
    });
    // Persist full snapshots in order, including rapid checkbox changes.
    _saveTail = _saveTail.then((_) async {
      try {
        await widget.onChanged(layout);
        _savedLayout = layout;
        if (mounted && revision == _revision) {
          setState(() => _saving = false);
        }
      } on Object {
        if (!mounted || revision != _revision) return;
        setState(() {
          _layout = _savedLayout;
          _saving = false;
          _saveFailed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，已恢复上次布局，请重试')),
        );
      }
    });
  }

  Future<void> _leaveWhenSaved() async {
    if (_leaving) return;
    _leaving = true;
    while (true) {
      final pending = _saveTail;
      await pending;
      if (identical(pending, _saveTail)) break;
    }
    _leaving = false;
    if (mounted && !_saveFailed) Navigator.of(context).pop();
  }

  void _addGroup() {
    _append(
        _layout.addGroup('custom_${DateTime.now().microsecondsSinceEpoch}'));
  }

  void _addDivider() {
    _append(
        _layout.addDivider('custom_${DateTime.now().microsecondsSinceEpoch}'));
  }

  void _append(HomeLayout layout) {
    _update(layout);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _dragHandle(int index, String title) {
    final handle = Semantics(
      label: '拖动$title',
      child: ColoredBox(
        color: Colors.transparent,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.drag_handle_rounded,
              color: context.shuyoColors.textMuted),
        ),
      ),
    );
    return ReorderableDragStartListener(index: index, child: handle);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveWhenSaved();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('首页布局'),
          actions: [
            TextButton(
              onPressed: () => _update(HomeLayout.defaults()),
              child: const Text('恢复默认'),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ReorderableListView.builder(
            scrollController: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            buildDefaultDragHandles: false,
            itemCount: _layout.entries.length,
            onReorderItem: (oldIndex, newIndex) =>
                _update(_layout.move(oldIndex, newIndex)),
            proxyDecorator: (child, index, animation) => Material(
              color: colors.surface,
              elevation: 3,
              borderRadius: BorderRadius.circular(12),
              child: child,
            ),
            itemBuilder: (context, index) {
              final entry = _layout.entries[index];
              return Padding(
                key: ValueKey(entry.key),
                padding: EdgeInsets.only(top: entry.isGroup ? 8 : 0),
                child: !entry.isModule
                    ? ListTile(
                        contentPadding:
                            const EdgeInsets.only(left: 16, right: 4),
                        title: Text(entry.isGroup ? '新卡片' : '分割线'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: ValueKey(entry.isGroup
                                  ? 'remove-group:${entry.groupId}'
                                  : 'remove-divider:${entry.dividerId}'),
                              tooltip: entry.isGroup ? '合并分组' : '删除分割线',
                              onPressed: () => _update(entry.isGroup
                                  ? _layout.removeGroup(entry.groupId!)
                                  : _layout.removeDivider(entry.dividerId!)),
                              icon: const Icon(Icons.remove_circle_outline,
                                  size: 20),
                            ),
                            _dragHandle(index, entry.isGroup ? '分组' : '分割线'),
                          ],
                        ),
                      )
                    : CheckboxListTile(
                        contentPadding:
                            const EdgeInsets.only(left: 8, right: 4),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(entry.module!.title),
                        value: entry.enabled,
                        onChanged: (value) => _update(
                            _layout.setEnabled(entry.module!, value ?? false)),
                        secondary: _dragHandle(index, entry.module!.title),
                      ),
              );
            },
            footer: Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _addGroup,
                        icon: const Icon(Icons.add),
                        label: const Text('添加分组'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _addDivider,
                        icon: const Icon(Icons.horizontal_rule),
                        label: const Text('添加分割线'),
                      ),
                    ],
                  ),
                  if (_saving || _saveFailed)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _saving ? '正在保存…' : '保存失败，已恢复上次布局',
                        style:
                            TextStyle(fontSize: 12.5, color: colors.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
