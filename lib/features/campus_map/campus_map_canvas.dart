import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../data/models/campus_map.dart';

class CampusMapCanvasConfiguration {
  const CampusMapCanvasConfiguration({
    required this.campus,
    required this.svg,
    required this.places,
    required this.accent,
    this.selectedPlaceId,
    this.location,
    this.focusPoint,
    this.focusRevision = 0,
    this.bottomInset = 0,
    this.active = true,
    this.onViewChanged,
  });

  final CampusMapCampus campus;
  final String svg;
  final List<CampusMapPlace> places;
  final Color accent;
  final String? selectedPlaceId;
  final Map<String, dynamic>? location;
  final CampusMapPoint? focusPoint;
  final int focusRevision;
  final double bottomInset;
  final bool active;
  final ValueChanged<CampusMapView>? onViewChanged;

  Color get backgroundColor => Color(campus.backgroundArgb);
}

typedef CampusMapCanvasBuilder = Widget Function(
  BuildContext context,
  CampusMapCanvasConfiguration configuration,
  ValueChanged<String> onPlaceTap,
  VoidCallback onMapTap,
);

/// Only the SVG canvas lives in a WebView. Search, sheets and platform actions
/// remain Flutter widgets, and the local document cannot navigate to the web.
class CampusMapCanvas extends StatefulWidget {
  const CampusMapCanvas({
    super.key,
    required this.configuration,
    required this.onPlaceTap,
    required this.onMapTap,
  });

  static const asset = 'assets/campus_map/canvas.html';
  static const _cachedGestures = bool.fromEnvironment(
    'CAMPUS_MAP_CACHED_GESTURES',
    defaultValue: true,
  );
  static const _androidHybridComposition = bool.fromEnvironment(
    'CAMPUS_MAP_ANDROID_HYBRID_COMPOSITION',
  );

  final CampusMapCanvasConfiguration configuration;
  final ValueChanged<String> onPlaceTap;
  final VoidCallback onMapTap;

  @override
  State<CampusMapCanvas> createState() => _CampusMapCanvasState();
}

class _CampusMapCanvasState extends State<CampusMapCanvas> {
  late final WebViewController _controller;
  late final WebViewWidget _webView;
  bool _syncing = false;
  bool _syncRequested = false;
  bool _ready = false;
  bool _failed = false;
  int _loadGeneration = 0;
  String? _campusId;
  int _focusRevision = -1;
  String? _lastUpdate;
  Timer? _loadTimeout;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.configuration.backgroundColor)
      ..addJavaScriptChannel('ShuyoMap', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final local = uri?.scheme == 'file' &&
              uri!.path.endsWith('/${CampusMapCanvas.asset}');
          return local || request.url == 'about:blank'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) _fail();
        },
      ));
    final gestures = <Factory<OneSequenceGestureRecognizer>>{
      Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
    };
    // Keep the display mode explicit and stable for the life of the native
    // view. The define allows device comparisons without exposing app settings.
    final PlatformWebViewWidgetCreationParams params;
    if (defaultTargetPlatform == TargetPlatform.android) {
      params = AndroidWebViewWidgetCreationParams(
        controller: _controller.platform,
        gestureRecognizers: gestures,
        displayWithHybridComposition: CampusMapCanvas._androidHybridComposition,
      );
    } else {
      params = PlatformWebViewWidgetCreationParams(
        controller: _controller.platform,
        gestureRecognizers: gestures,
      );
    }
    _webView = WebViewWidget.fromPlatformCreationParams(params: params);
    unawaited(_load());
  }

  Future<void> _load() async {
    _loadGeneration++;
    _ready = false;
    _campusId = null;
    _focusRevision = -1;
    _lastUpdate = null;
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 12), _fail);
    try {
      await _controller.loadFlutterAsset(CampusMapCanvas.asset);
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (!mounted) return;
    _loadTimeout?.cancel();
    setState(() => _failed = true);
  }

  void _onMessage(JavaScriptMessage message) {
    if (!mounted) return;
    try {
      final value = jsonDecode(message.message) as Map<String, dynamic>;
      switch (value['type']) {
        case 'ready':
          _loadTimeout?.cancel();
          setState(() {
            _ready = true;
            _failed = false;
          });
          _sync();
        case 'place':
          final id = value['id'];
          if (widget.configuration.active &&
              id is String &&
              widget.configuration.places.any((place) => place.id == id)) {
            widget.onPlaceTap(id);
          }
        case 'background':
          if (widget.configuration.active) widget.onMapTap();
        case 'viewport':
          if (kDebugMode &&
              value['campusId'] == widget.configuration.campus.id) {
            widget.configuration.onViewChanged?.call(
              CampusMapView.fromJson(value['view'] as Map<String, dynamic>),
            );
          }
        case 'error':
          _fail();
      }
    } on FormatException {
      // Ignore messages that are not part of the local canvas protocol.
    } on TypeError {
      // The channel accepts no commands, URLs or arbitrary native operations.
    }
  }

  @override
  void didUpdateWidget(covariant CampusMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _syncRequested = true;
    if (_syncing || !_canSync) return;
    unawaited(_drainSync());
  }

  bool get _canSync => mounted && _ready && !_failed;

  Future<void> _drainSync() async {
    _syncing = true;
    var generation = _loadGeneration;
    try {
      // Keep one pending update while the platform channel is busy. Panel and
      // keyboard animations can otherwise enqueue many obsolete camera states.
      while (_syncRequested && _canSync) {
        _syncRequested = false;
        generation = _loadGeneration;
        final c = widget.configuration;
        if (_campusId != c.campus.id) {
          await _controller.setBackgroundColor(c.backgroundColor);
          if (!_canSync || generation != _loadGeneration) continue;
          if (widget.configuration.campus.id != c.campus.id) {
            _syncRequested = true;
            continue;
          }
          await _call('load', {
            'campusId': c.campus.id,
            'svg': c.svg,
            'viewBox': c.campus.viewBox,
            'initialView': c.campus.initialView.toJson(),
            'backgroundColor': c.campus.backgroundColor,
            'debug': kDebugMode,
            'places': c.places.map((place) => place.toCanvasJson()).toList(),
            'bottomInset': c.bottomInset,
            'cachedGestures': CampusMapCanvas._cachedGestures,
            'active': c.active,
          });
          if (!_canSync || generation != _loadGeneration) continue;
          _campusId = c.campus.id;
          _focusRevision = -1;
          _lastUpdate = null;
        }
        if (!identical(c, widget.configuration)) {
          _syncRequested = true;
          continue;
        }
        final update = {
          'selectedId': c.selectedPlaceId,
          'location': c.location,
          'accent': '#${c.accent.toARGB32().toRadixString(16).substring(2)}',
          'bottomInset': c.bottomInset,
          'focusPoint': c.focusPoint?.toJson(),
          'active': c.active,
        };
        final encoded = jsonEncode(update);
        final focus = _focusRevision != c.focusRevision;
        if (!focus && encoded == _lastUpdate) continue;
        await _call('update', {...update, 'focus': focus});
        if (!_canSync || generation != _loadGeneration) continue;
        _focusRevision = c.focusRevision;
        _lastUpdate = encoded;
      }
    } catch (_) {
      if (generation == _loadGeneration) _fail();
    } finally {
      _syncing = false;
      if (_syncRequested && _canSync) _sync();
    }
  }

  Future<void> _call(String method, Map<String, dynamic> value) => _controller
      .runJavaScript('window.campusMap.$method(${jsonEncode(value)});');

  @override
  void dispose() {
    _loadTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 36),
            const SizedBox(height: 12),
            const Text('地图画布加载失败'),
            TextButton(
              onPressed: () {
                setState(() => _failed = false);
                unawaited(_load());
              },
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    return Semantics(
      label: '${widget.configuration.campus.name}地图，支持双指缩放与拖动，也可通过搜索查找地点',
      child: Stack(
        fit: StackFit.expand,
        children: [
          _webView,
          if (!_ready) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
