import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/campus_map.dart';
import '../../shared/theme/shuyo_theme.dart';

/// A compact sheet whose information can resize above a fixed bottom action.
class CampusMapPlaceDetails extends StatelessWidget {
  const CampusMapPlaceDetails({
    super.key,
    required this.place,
    required this.campusName,
    required this.onClose,
    required this.onNavigate,
    required this.onHeightChanged,
    required this.maxHeight,
  });

  final CampusMapPlace place;
  final String campusName;
  final VoidCallback onClose;
  final VoidCallback onNavigate;
  final ValueChanged<double> onHeightChanged;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final name = normalizeCampusMapSearch(place.name);
    final aliases = place.aliases.where((alias) {
      final text = normalizeCampusMapSearch(alias);
      return text.length > 1 && !name.contains(text);
    }).toList(growable: false);
    return _MeasureHeight(
      onHeightChanged: onHeightChanged,
      child: Material(
        elevation: 12,
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          // Keep the background painted to the screen edge while the content
          // stays above the home indicator and system navigation controls.
          child: SafeArea(
            maintainBottomViewPadding: true,
            top: false,
            left: false,
            right: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  fit: FlexFit.loose,
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          for (final child in previousChildren)
                            Positioned.fill(child: IgnorePointer(child: child)),
                          if (currentChild != null) currentChild,
                        ],
                      ),
                      child: SingleChildScrollView(
                        key: ValueKey(place.id),
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(place.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '关闭地点详情',
                                  icon: const Icon(Icons.close),
                                  onPressed: onClose,
                                ),
                              ],
                            ),
                            Text('$campusName · ${place.kind}',
                                style: TextStyle(color: colors.textTertiary)),
                            const SizedBox(height: 14),
                            _DetailRow(
                              icon: Icons.place_outlined,
                              label: '位置',
                              value: place.address.isEmpty
                                  ? campusName
                                  : place.address,
                            ),
                            if (aliases.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _DetailRow(
                                icon: Icons.label_outline,
                                label: '其他名称',
                                value: aliases.join('、'),
                              ),
                            ],
                            if (place.description.isNotEmpty &&
                                place.description != place.name) ...[
                              const SizedBox(height: 12),
                              Text(place.description,
                                  style: const TextStyle(height: 1.6)),
                            ],
                            for (final fact in place.facts) ...[
                              const SizedBox(height: 10),
                              _DetailRow(
                                icon: Icons.info_outline,
                                label: fact.label,
                                value: fact.value,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.directions_walk),
                    label: Text(place.navigation == null ? '暂无导航坐标' : '导航到这里'),
                    onPressed: place.navigation == null ? null : onNavigate,
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: colors.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: colors.textTertiary)),
              const SizedBox(height: 3),
              SelectableText(value,
                  style: TextStyle(color: colors.textSecondary, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }
}

class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required super.child, required this.onHeightChanged});

  final ValueChanged<double> onHeightChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onHeightChanged);

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderMeasureHeight renderObject) {
    renderObject.onHeightChanged = onHeightChanged;
  }
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeightChanged);

  ValueChanged<double> onHeightChanged;
  double? _height;
  bool _scheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_scheduled ||
        (_height != null && (size.height - _height!).abs() <= .5)) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (attached) {
        _height = size.height;
        onHeightChanged(size.height);
      }
    });
  }
}
