import 'package:flutter/material.dart';

import '../theme/shuyo_theme.dart';

/// The underlined search field used by the in-app search pages.
///
/// The focus ring is the only affordance: pages that search as the user types
/// do not need a submit button next to it.
class ShuYoSearchField extends StatefulWidget {
  const ShuYoSearchField({
    super.key,
    this.controller,
    this.hintText = '搜索课程、教师或课程号',
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
  });

  final TextEditingController? controller;
  final String hintText;
  final bool autofocus;
  final bool readOnly;
  final VoidCallback? onTap;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;

  @override
  State<ShuYoSearchField> createState() => _ShuYoSearchFieldState();
}

class _ShuYoSearchFieldState extends State<ShuYoSearchField> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final focused = _focusNode.hasFocus;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: focused ? colors.accent : colors.borderStrong,
            width: focused ? 1.5 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _focusNode.requestFocus,
            excludeFromSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 12),
              child: Icon(Icons.search, size: 20, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              readOnly: widget.readOnly,
              onTap: widget.onTap,
              onTapOutside: (_) => _focusNode.unfocus(),
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
              ),
              textInputAction: TextInputAction.search,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}
