import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models/campus_map.dart';
import '../../data/repositories/campus_map_repository.dart';
import '../../data/services/campus_map_location_service.dart';
import '../../data/services/campus_map_navigation_service.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'campus_map_canvas.dart';
import 'campus_map_place_details.dart';

class CampusMapPage extends StatefulWidget {
  const CampusMapPage({
    super.key,
    this.initialCampus = '宝山校区',
    this.repository,
    this.locationService = const CampusMapLocationService(),
    this.navigationService,
    this.canvasBuilder,
  });

  final String initialCampus;
  final CampusMapRepository? repository;
  final CampusMapLocationService locationService;
  final CampusMapNavigationService? navigationService;
  final CampusMapCanvasBuilder? canvasBuilder;

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage>
    with WidgetsBindingObserver {
  late final _repository = widget.repository ?? CampusMapRepository.shared;
  late final _navigation =
      widget.navigationService ?? CampusMapNavigationService();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  (CampusMapData, String, String)? _searchKey;
  List<CampusMapPlace> _searchMatches = const [];
  CampusMapView? _debugView;
  Timer? _debugTimer;
  CampusMapData? _data;
  CampusMapCampus? _campus;
  CampusMapPlace? _selected;
  String? _svg;
  bool _loadFailed = false;
  bool _svgFailed = false;
  bool _searching = false;
  bool _locating = false;
  bool _watchEnabled = false;
  bool _obscured = false;
  bool _navigationOpen = false;
  int _campusRequest = 0;
  int _locationRequest = 0;
  int _watchRequest = 0;
  int _focusRevision = 0;
  double _detailHeight = 0;
  CampusMapLocation? _location;
  CampusMapPoint? _focusPoint;
  StreamSubscription<CampusMapLocation>? _positionSubscription;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(_focusChanged);
    if (kDebugMode) {
      _debugTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        final view = _debugView;
        if (_foreground && !_searching && !_obscured && view != null) {
          debugPrint(
              '[CAMPUS_MAP_VIEW] ${_campus?.id} initialView=${jsonEncode(view.toJson())}');
        }
      });
    }
    unawaited(_load());
  }

  void _focusChanged() {
    if (!mounted || !_searchFocus.hasFocus) return;
    setState(() {
      _searching = true;
      _selected = null;
      _focusPoint = null;
    });
  }

  Future<void> _load() async {
    try {
      final data = await _repository.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loadFailed = false;
      });
      await _changeCampus(data.initialCampus(widget.initialCampus));
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _changeCampus(
    CampusMapCampus campus, {
    bool preserveSelection = false,
  }) async {
    if (_campus?.id == campus.id && _svg != null) return;
    final request = ++_campusRequest;
    if (!mounted) return;
    setState(() {
      _campus = campus;
      _debugView = null;
      _svg = null;
      _svgFailed = false;
      if (!preserveSelection) {
        _selected = null;
        _focusPoint = null;
      }
    });
    try {
      final svg = await _repository.loadSvg(campus);
      if (!mounted || request != _campusRequest) return;
      setState(() => _svg = svg);
    } catch (_) {
      if (mounted && request == _campusRequest) {
        setState(() => _svgFailed = true);
      }
    }
  }

  void _selectPlace(CampusMapPlace place) {
    _searchFocus.unfocus();
    setState(() {
      _searchController.clear();
      _selected = place;
      _searching = false;
      _focusPoint = null;
      _focusRevision++;
    });
    unawaited(_changeCampus(
      _data!.campusById[place.campusId]!,
      preserveSelection: true,
    ));
  }

  void _closeDetail() {
    setState(() {
      _selected = null;
      _focusPoint = null;
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchController.clear();
      _searching = false;
    });
  }

  void _back() {
    if (_searching) {
      _closeSearch();
      return;
    }
    if (_selected != null) {
      _closeDetail();
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _mapTap() {
    if (_selected != null) {
      _closeDetail();
    } else if (_searching) {
      _closeSearch();
    }
  }

  void _onViewChanged(CampusMapView view) {
    _debugView = view;
  }

  Future<void> _locate() async {
    if (_locating) return;
    final request = ++_locationRequest;
    setState(() => _locating = true);
    try {
      final position = await widget.locationService.locate();
      if (!mounted || request != _locationRequest || !_foreground) return;
      final campus = _data!.campusAt(position.coordinate);
      setState(() {
        _location = position;
        _watchEnabled = true;
      });
      unawaited(_startWatching());
      if (campus == null) {
        _showMessage('当前位置不在校区地图范围内');
        return;
      }
      _searchFocus.unfocus();
      setState(() {
        _selected = null;
        _searching = false;
        _searchController.clear();
        _focusPoint = campus.project(position.coordinate);
        _focusRevision++;
      });
      await _changeCampus(campus, preserveSelection: true);
      if (mounted && position.accuracy > 100) {
        _showMessage('当前定位精度较低，位置仅供参考');
      }
    } on CampusMapLocationException catch (error) {
      if (mounted && request == _locationRequest && _foreground) {
        _showLocationError(error);
      }
    } catch (_) {
      if (mounted && request == _locationRequest && _foreground) {
        _showMessage('定位失败，请检查定位权限后重试');
      }
    } finally {
      if (mounted && request == _locationRequest) {
        setState(() => _locating = false);
      }
    }
  }

  Future<void> _startWatching() async {
    final request = ++_watchRequest;
    final previous = _positionSubscription;
    _positionSubscription = null;
    await previous?.cancel();
    if (!mounted || !_foreground || !_watchEnabled || _obscured) return;
    try {
      final allowed = await widget.locationService.canWatch();
      if (!mounted || request != _watchRequest || !_foreground || _obscured) {
        return;
      }
      if (!allowed) {
        setState(() => _location = null);
        return;
      }
      _positionSubscription = widget.locationService.watch().listen(
        (position) {
          if (!mounted || request != _watchRequest || !_foreground) return;
          try {
            position.coordinate;
            setState(() => _location = position);
          } catch (_) {
            // Do not project non-finite device coordinates onto the map.
          }
        },
        onError: (Object error) {
          if (mounted && request == _watchRequest) {
            setState(() => _location = null);
          }
        },
      );
    } catch (_) {
      if (mounted && request == _watchRequest) {
        setState(() => _location = null);
      }
    }
  }

  void _stopWatching() {
    _watchRequest++;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_watchEnabled) unawaited(_startWatching());
    } else if (state != AppLifecycleState.inactive) {
      _locationRequest++;
      _stopWatching();
      if (mounted) {
        setState(() {
          _locating = false;
          _location = null;
        });
      }
    }
  }

  void _showLocationError(CampusMapLocationException error) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error.message),
      action: error.action == null
          ? null
          : SnackBarAction(
              label: '去设置',
              onPressed: () => unawaited(_openLocationSettings(error.action!)),
            ),
    ));
  }

  Future<void> _openLocationSettings(CampusMapLocationAction action) async {
    try {
      if (!await widget.locationService.openSettings(action) && mounted) {
        _showMessage('请在系统设置中开启定位权限');
      }
    } catch (_) {
      if (mounted) _showMessage('请在系统设置中开启定位权限');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openNavigation(CampusMapPlace place) async {
    if (_navigationOpen || place.navigation == null) return;
    _navigationOpen = true;
    _obscured = true;
    _stopWatching();
    _searchFocus.unfocus();
    try {
      final provider = await showModalBottomSheet<CampusMapNavigationProvider>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('导航至 ${place.name}',
                  style: Theme.of(context).textTheme.titleMedium),
              for (final provider in CampusMapNavigationProvider.values)
                ListTile(
                  leading: const Icon(Icons.directions_walk),
                  title: Text(provider.label),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => Navigator.pop(context, provider),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (provider != null && mounted) await _navigation.open(provider, place);
    } on CampusMapNavigationException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('无法打开导航，请稍后重试');
    } finally {
      _navigationOpen = false;
      _obscured = false;
      if (mounted && _watchEnabled && _foreground) {
        unawaited(_startWatching());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationRequest++;
    _stopWatching();
    _searchFocus.removeListener(_focusChanged);
    _searchFocus.dispose();
    _searchController.dispose();
    _debugTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = !_searchFocus.hasFocus && !_searching && _selected == null;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: GestureDetector(
        // Let result taps, text editing and list scrolling win the gesture
        // arena. Closing on pointer-down would remove a result before its tap.
        behavior: HitTestBehavior.opaque,
        onTap: _searching ? _closeSearch : null,
        child: Scaffold(
          // Only the lightweight search overlay follows the keyboard. Resizing
          // the native map here invalidates its SVG cache on every inset update.
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            leading: IconButton(
              tooltip: '返回',
              icon: const Icon(Icons.arrow_back),
              onPressed: _back,
            ),
            title: const Text('校园地图'),
            actions: [
              IconButton(
                tooltip: '地图说明',
                icon: const Icon(Icons.info_outline),
                onPressed: _showAbout,
              ),
            ],
          ),
          // Let the map and panel background reach the gesture/navigation area.
          // Interactive controls apply their own bottom safe-area spacing.
          body: SafeArea(top: false, bottom: false, child: _body()),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loadFailed) {
      return _errorState('地图读取失败', () {
        setState(() => _loadFailed = false);
        unawaited(_load());
      });
    }
    if (_data == null || _campus == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final colors = context.shuyoColors;
    final data = _data!;
    final campus = _campus!;
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(
            children: [
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: campus.id,
                  borderRadius: BorderRadius.zero,
                  onTap: _searching ? _closeSearch : null,
                  items: [
                    for (final item in data.campuses)
                      DropdownMenuItem(value: item.id, child: Text(item.name)),
                  ],
                  onChanged: (id) {
                    if (id != null && id != campus.id) {
                      _closeSearch();
                      unawaited(_changeCampus(data.campusById[id]!));
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() => _searching = true),
                  onSubmitted: (_) => _searchFocus.unfocus(),
                  decoration: InputDecoration(
                    hintText: '搜索全部校区',
                    isDense: true,
                    filled: true,
                    fillColor: colors.surfaceAlt,
                    prefixIcon: const Icon(Icons.search, size: 21),
                    suffixIcon: _searching || _searchController.text.isNotEmpty
                        ? IconButton(
                            tooltip: _searchController.text.isEmpty
                                ? '关闭搜索'
                                : '清空搜索',
                            icon: const Icon(Icons.close, size: 19),
                            onPressed: () {
                              if (_searchController.text.isEmpty) {
                                _closeSearch();
                              } else {
                                setState(_searchController.clear);
                              }
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.border),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final sheetHeight = _selected == null
                ? 0.0
                : (_detailHeight == 0
                    ? constraints.maxHeight * .4
                    : _detailHeight.clamp(0.0, constraints.maxHeight * .72));
            return Stack(
              fit: StackFit.expand,
              children: [
                if (_svgFailed)
                  _errorState('校区底图读取失败', () {
                    unawaited(_changeCampus(campus, preserveSelection: true));
                  })
                else if (_svg == null)
                  const Center(child: CircularProgressIndicator())
                else
                  _canvas(campus, sheetHeight),
                if (!_searching) ...[
                  Positioned(
                    right: 16,
                    bottom:
                        ((_selected == null ? bottomPadding : sheetHeight) + 16)
                            .clamp(
                                12.0,
                                (constraints.maxHeight - 56)
                                    .clamp(12.0, double.infinity)),
                    child: _mapButton(
                      tooltip: '定位到我的位置',
                      icon: Icons.my_location,
                      busy: _locating,
                      onPressed: () => unawaited(_locate()),
                    ),
                  ),
                ],
                if (_searching) _searchResults(),
                if (_selected != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: CampusMapPlaceDetails(
                      place: _selected!,
                      campusName: data.campusById[_selected!.campusId]!.name,
                      maxHeight: constraints.maxHeight * .72,
                      onClose: _closeDetail,
                      onNavigate: () => unawaited(_openNavigation(_selected!)),
                      onHeightChanged: (height) {
                        if (mounted &&
                            _selected != null &&
                            (height - _detailHeight).abs() > .5) {
                          setState(() => _detailHeight = height);
                        }
                      },
                    ),
                  ),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _canvas(CampusMapCampus campus, double bottomInset) {
    final configuration = CampusMapCanvasConfiguration(
      campus: campus,
      svg: _svg!,
      places: _data!.places
          .where((place) => place.campusId == campus.id)
          .toList(growable: false),
      selectedPlaceId: _selected?.id,
      location: _location?.forCampus(campus),
      focusPoint: _focusPoint,
      focusRevision: _focusRevision,
      bottomInset: bottomInset,
      active: !_searching,
      accent: context.shuyoColors.accent,
      onViewChanged: kDebugMode ? _onViewChanged : null,
    );
    void onPlaceTap(String id) {
      final place = _data!.placeById[id];
      if (place != null) _selectPlace(place);
    }

    return widget.canvasBuilder?.call(
          context,
          configuration,
          onPlaceTap,
          _mapTap,
        ) ??
        CampusMapCanvas(
          configuration: configuration,
          onPlaceTap: onPlaceTap,
          onMapTap: _mapTap,
        );
  }

  Widget _searchResults() {
    final data = _data!;
    final query = _searchController.text;
    final key = (data, query, _campus!.id);
    if (_searchKey != key) {
      _searchKey = key;
      _searchMatches = data.search(query, preferredCampusId: _campus!.id);
    }
    final places = _searchMatches;
    final results = SafeArea(
      key: const ValueKey('campus-map-search-results'),
      top: false,
      left: false,
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              query.trim().isEmpty
                  ? '搜索教学楼、图书馆、食堂等地点'
                  : '共找到 ${places.length} 个地点',
              style: TextStyle(color: context.shuyoColors.textTertiary),
            ),
          ),
          Expanded(
            child: places.isEmpty
                ? Center(
                    child: Text(query.trim().isEmpty
                        ? '输入地点或学院名称查找'
                        : '未找到相关地点，试试其他名称'),
                  )
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: places.length,
                    itemBuilder: (context, index) {
                      final place = places[index];
                      return ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(place.name),
                        subtitle: Text(
                          '${data.campusById[place.campusId]!.name} · ${place.kind}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _selectPlace(place),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
    return Material(
      color: context.shuyoColors.surface,
      child: Builder(builder: (context) {
        // Inset changes rebuild and lay out this overlay, not the map or search
        // matching. Its opaque background also blocks taps through to the map.
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: results,
        );
      }),
    );
  }

  Widget _mapButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool busy = false,
  }) =>
      Material(
        elevation: 3,
        color: context.shuyoColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: IconButton(
          tooltip: tooltip,
          onPressed: busy ? null : onPressed,
          icon: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
        ),
      );

  Widget _errorState(String text, VoidCallback retry) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 36),
            const SizedBox(height: 12),
            Text(text),
            TextButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      );

  Future<void> _showAbout() async {
    if (_searching) _closeSearch();
    _obscured = true;
    _searchFocus.unfocus();
    _stopWatching();
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('校园地图'),
          content: const Text(
            '校园地图为离线功能，地图与地点资料来自「上海大学交通社 SHUMap」\n\n可访问  https://map.shutf.com/map 获取最新地图。\n\n感谢交通社的付出！',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      _obscured = false;
      if (mounted && _watchEnabled && _foreground) {
        unawaited(_startWatching());
      }
    }
  }
}
