import 'package:material_ui/material_ui.dart';

class WebVpnToggle extends StatefulWidget {
  const WebVpnToggle({
    super.key,
    required this.value,
    required this.changing,
    required this.onChanged,
  });

  final bool value;
  final bool changing;
  final ValueChanged<bool>? onChanged;

  @override
  State<WebVpnToggle> createState() => _WebVpnToggleState();
}

class _WebVpnToggleState extends State<WebVpnToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  late final Animation<Offset> _drop;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
      value: widget.changing ? 1 : 0,
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _drop = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(_progress);
  }

  @override
  void didUpdateWidget(covariant WebVpnToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.changing == oldWidget.changing) return;
    if (widget.changing) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox(
        width: 64,
        height: 74,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Switch(
                value: widget.value,
                onChanged: widget.changing ? null : widget.onChanged,
              ),
            ),
            if (_controller.value > 0)
              Positioned(
                top: 52,
                left: 23,
                child: SlideTransition(
                  position: _drop,
                  child: FadeTransition(
                    opacity: _progress,
                    child: const IgnorePointer(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
