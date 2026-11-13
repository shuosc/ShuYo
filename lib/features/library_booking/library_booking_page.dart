import 'dart:async';
import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPicker;
import 'package:material_ui/material_ui.dart';

import '../../data/models/classroom.dart';
import '../../data/services/academic_account_store.dart';
import '../../data/services/chaoxing_booking_adapter.dart';
import '../../data/services/chaoxing_booking_client.dart';
import '../../data/services/library_booking_cache.dart';
import '../../data/services/there_booking_client.dart';
import '../../data/services/unified_account_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/custom_background.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';
import '../auth/native_login_page.dart';
import 'library_booking_list_tile.dart';
import 'library_booking_names.dart';
import 'library_booking_record.dart';
import 'library_booking_resources.dart';

enum _BookingStep {
  venue,
  area,
  viewVenues,
  allAreas,
  time,
  seat,
  bookings,
}

/// Keeps elapsed time visible on today's scale while marking it unavailable.
class _PastTimeRangeTrackShape extends RoundedRectRangeSliderTrackShape {
  const _PastTimeRangeTrackShape({
    required this.disabledFraction,
    required this.disabledColor,
  });

  final double disabledFraction;
  final Color disabledColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset startThumbCenter,
    required Offset endThumbCenter,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      startThumbCenter: startThumbCenter,
      endThumbCenter: endThumbCenter,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    if (disabledFraction <= 0) return;
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final width = track.width * disabledFraction.clamp(0.0, 1.0);
    final disabled = textDirection == TextDirection.ltr
        ? Rect.fromLTWH(track.left, track.top, width, track.height)
        : Rect.fromLTWH(track.right - width, track.top, width, track.height);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(disabled, Radius.circular(track.height / 2)),
      Paint()..color = disabledColor,
    );
  }
}

class _PrefetchedBookingDay {
  const _PrefetchedBookingDay({
    required this.areaData,
    required this.minMinutes,
    required this.start,
    required this.end,
    this.available,
    this.rooms = const [],
    this.previewError,
  });

  final Map<String, dynamic> areaData;
  final int minMinutes;
  final String start;
  final String end;
  final int? available;
  final List<Map<String, dynamic>> rooms;
  final String? previewError;
}

enum _BookingCampus {
  baoshan('宝山校区', [
    BookingVenue.library,
    BookingVenue.studySpace,
    BookingVenue.qianweichang,
  ]),
  yanchang('延长校区', [
    BookingVenue.scienceArt,
    BookingVenue.yanchang,
    BookingVenue.wenhui,
  ]),
  jiading('嘉定校区', [BookingVenue.jiading]);

  const _BookingCampus(this.label, this.venues);

  final String label;
  final List<BookingVenue> venues;

  static _BookingCampus fromPreferredCampus(String campus) => switch (campus) {
        '延长' => yanchang,
        '嘉定' => jiading,
        _ => baoshan,
      };

  static String venueLabel(BookingVenue venue) {
    final campus =
        values.where((item) => item.venues.contains(venue)).firstOrNull;
    final venueName = LibraryBookingNames.venue(venue);
    return campus == null ? venueName : '${campus.label} $venueName';
  }
}

class LibraryBookingPage extends StatefulWidget {
  const LibraryBookingPage({
    super.key,
    required this.accountService,
    this.thereClientFactory,
    this.chaoxingClient,
    this.useWebVpn = false,
    this.onWebVpnSessionRequired,
    this.onChaoxingLoginRequired,
    this.onCampusLoginRequired,
    this.onCampusSessionExpired,
    this.onWebVpnRecoveryRequired,
    this.initialCampus = ClassroomCampus.defaultName,
    this.schoolClock,
  });

  final UnifiedAccountService accountService;
  final ThereBookingClient Function(BookingVenue)? thereClientFactory;
  final ChaoxingBookingClient? chaoxingClient;
  final bool useWebVpn;
  final Future<bool> Function()? onWebVpnSessionRequired;
  final Future<bool> Function()? onChaoxingLoginRequired;
  final Future<bool> Function()? onCampusLoginRequired;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;
  final Future<bool> Function(bool interactive)? onWebVpnRecoveryRequired;
  final String initialCampus;

  /// Shanghai wall-clock time, overridable for deterministic time selection.
  final DateTime Function()? schoolClock;

  @override
  State<LibraryBookingPage> createState() => _LibraryBookingPageState();
}

class _LibraryBookingPageState extends State<LibraryBookingPage> {
  static const double _timeDigitFontSize = 22;
  static const _snapshotLifetime = Duration(seconds: 60);

  final Map<BookingVenue, ThereBookingClient> _thereClients = {};
  final Map<BookingVenue, ChaoxingBookingAdapter> _chaoxingAdapters = {};
  final Map<BookingVenue, Future<void>> _pendingVenueSelections = {};
  ChaoxingBookingClient? _ownedChaoxingClient;
  Future<List<Map<String, dynamic>>>? _sharedChaoxingRoomLoad;
  bool _sharedChaoxingRoomLoadPending = false;
  DateTime? _sharedChaoxingRoomLoadAt;
  String? _sharedChaoxingRoomDay;
  BookingVenue _activeClientVenue = BookingVenue.library;
  ThereBookingClient get _client => _clientForVenue(_activeClientVenue);

  Future<List<Map<String, dynamic>>> _loadSharedChaoxingRooms() {
    final now = DateTime.now();
    final day = _clockDay;
    final pending = _sharedChaoxingRoomLoad;
    final fetchedAt = _sharedChaoxingRoomLoadAt;
    if (pending != null &&
        _sharedChaoxingRoomDay == day &&
        (_sharedChaoxingRoomLoadPending ||
            (fetchedAt != null &&
                now.difference(fetchedAt) < const Duration(seconds: 5)))) {
      return pending;
    }
    final client = widget.chaoxingClient ??
        (_ownedChaoxingClient ??= ChaoxingBookingClient());
    final load = client.rooms();
    _sharedChaoxingRoomLoad = load;
    _sharedChaoxingRoomLoadPending = true;
    _sharedChaoxingRoomLoadAt = null;
    _sharedChaoxingRoomDay = day;
    unawaited(load.then<void>((_) {
      if (identical(_sharedChaoxingRoomLoad, load)) {
        _sharedChaoxingRoomLoadPending = false;
        _sharedChaoxingRoomLoadAt = DateTime.now();
      }
    }, onError: (Object _, StackTrace __) {
      if (identical(_sharedChaoxingRoomLoad, load)) {
        _sharedChaoxingRoomLoad = null;
        _sharedChaoxingRoomLoadPending = false;
        _sharedChaoxingRoomLoadAt = null;
      }
    }));
    return load;
  }

  ThereBookingClient _clientForVenue(BookingVenue venue) => venue.isChaoxing
      ? _chaoxingAdapters.putIfAbsent(
          venue,
          () => ChaoxingBookingAdapter(
            client: widget.chaoxingClient ??
                (_ownedChaoxingClient ??= ChaoxingBookingClient()),
            schoolClock: () => _schoolNow,
            loadRooms: _loadSharedChaoxingRooms,
          ),
        )
      : _thereClients.putIfAbsent(
          venue,
          () =>
              widget.thereClientFactory?.call(venue) ??
              ThereBookingClient(useWebVpn: widget.useWebVpn),
        );

  Future<void> _ensureVenueSelected(
      BookingVenue venue, ThereBookingClient client) async {
    final pending = _pendingVenueSelections[venue];
    if (pending != null) return pending;
    final selection = client.selectVenue(venue);
    _pendingVenueSelections[venue] = selection;
    try {
      await selection;
    } finally {
      if (identical(_pendingVenueSelections[venue], selection)) {
        _pendingVenueSelections.remove(venue);
      }
    }
  }

  Future<void> _selectBookingVenue(BookingVenue venue,
      {bool refresh = false}) async {
    final client = _clientForVenue(venue);
    _activeClientVenue = venue;
    if (refresh) {
      final pending = _pendingVenueSelections[venue];
      if (pending != null) {
        try {
          await pending;
        } on Object {
          // A fresh entry request can recover a failed background selection.
        }
      }
      await client.refreshVenue(venue);
    } else {
      await _ensureVenueSelected(venue, client);
    }
  }

  _BookingStep _step = _BookingStep.venue;
  late _BookingCampus _campus;
  bool _slideForward = true;
  BookingVenue _venue = BookingVenue.library;
  bool _viewOnly = false;
  bool _areaSelectionFromHome = false;
  final Set<BookingVenue> _viewVenueSelection = {};
  final Set<BookingVenue> _expandedVenues = {};
  final Map<BookingVenue, List<Map<String, dynamic>>> _homeAreasByVenue = {};
  final Map<BookingVenue, Future<void>> _homeAreaLoads = {};
  final Map<BookingVenue, DateTime> _homeAreasUpdatedAt = {};
  final Set<BookingVenue> _loadingHomeAreas = {};
  final Map<BookingVenue, String> _homeAreaErrors = {};
  final Map<BookingVenue, int> _homeAreaGenerations = {};
  late String _day;
  List<String> _days = [];
  final Map<String, _PrefetchedBookingDay> _prefetchedDays = {};
  final Map<String, String> _dayRuleErrors = {};
  List<Map<String, dynamic>> _areas = [];
  final Map<BookingVenue, List<Map<String, dynamic>>> _allAreasByVenue = {};
  bool _loadingAllAreas = false;
  String? _allAreasError;
  Map<String, dynamic>? _selectedArea;
  Map<String, dynamic>? _profile;
  Map<String, dynamic>? _areaData;
  List<Map<String, dynamic>> _rooms = [];
  final List<Map<String, dynamic>> _recent = [];
  final LibraryBookingCache _bookingCache = LibraryBookingCache();
  List<Map<String, dynamic>> _homeRecent = [];
  List<Map<String, dynamic>> _cachedHistory = [];
  final Set<String> _homeRefreshedRoomTypes = {};
  String? _cacheStudentId;
  bool _homeCacheLoaded = false;
  bool _homeCacheLoading = false;
  int _homeRecordsRevision = 0;
  int _historyRecordsRevision = 0;
  Future<void> _bookingCacheWriteQueue = Future<void>.value();
  final Map<String, Map<String, dynamic>> _prefetchedDetails = {};
  final Set<String> _openingDetails = {};
  final Map<String, bool> _awaitingWriteStatus = {};
  String _start = '08:00';
  String _end = '08:30';
  int _effectiveMinMinutes = 1;
  bool _loadingAreaRules = false;
  String? _areaRulesError;
  bool _timeRangeDragging = false;

  DateTime get _schoolNow =>
      widget.schoolClock?.call() ??
      DateTime.now().toUtc().add(const Duration(hours: 8));

  String get _clockDay {
    final now = _schoolNow;
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  int? _previewAvailable;
  List<Map<String, dynamic>> _previewRooms = [];
  bool _previewLoading = false;
  String? _previewError;
  String? _previewKey;
  int _previewGeneration = 0;
  String _seatFilter = '';
  bool _onlyAvailable = false;
  String? _selectedRoomId;
  String? _seatSelectionDraftId;
  String? _error;
  String _loadingLabel = '';
  bool _loading = false;
  bool _loadingSeats = false;
  bool _busy = false;
  int _generation = 0;
  Future<void> _authenticationQueue = Future<void>.value();
  int _authenticationRevision = 0;
  String _bookingFilter = '全部';
  int _bookingAnimationEpoch = 0;
  final Map<BookingVenue, Future<bool>> _bookingLoads = {};
  final Map<BookingVenue, DateTime> _bookingsUpdatedAt = {};
  final Set<BookingVenue> _bookingLoadFailures = {};

  bool get _bookingsIncomplete => _bookingLoadFailures.isNotEmpty;
  bool get _bookingsLoading => _bookingLoads.isNotEmpty;

  bool _isFresh(DateTime? updatedAt) {
    if (updatedAt == null) return false;
    final now = _schoolNow;
    final age = now.difference(updatedAt);
    return DateUtils.isSameDay(updatedAt, now) &&
        age >= Duration.zero &&
        age < _snapshotLifetime;
  }

  @override
  void initState() {
    super.initState();
    _campus = _BookingCampus.fromPreferredCampus(widget.initialCampus);
    _day = _clockDay;
    unawaited(_refreshHomeData());
  }

  @override
  void dispose() {
    if (widget.thereClientFactory == null) {
      for (final client in _thereClients.values) {
        client.dispose();
      }
    }
    for (final adapter in _chaoxingAdapters.values) {
      adapter.dispose();
    }
    _ownedChaoxingClient?.dispose();
    super.dispose();
  }

  void _setStep(_BookingStep step, {bool forward = false}) {
    final enteringHome =
        _step != _BookingStep.venue && step == _BookingStep.venue;
    ++_generation;
    setState(() {
      _slideForward = forward;
      _step = step;
      _loading = false;
      _loadingSeats = false;
      _loadingAllAreas = false;
      _error = null;
    });
    if (enteringHome) unawaited(_refreshHomeData());
  }

  Future<void> _refreshHomeData({bool force = false}) async {
    if (!_homeCacheLoaded) unawaited(_loadHomeCache());
    await Future.wait([
      _loadBookings(showFailures: force, force: force),
      _loadHomeCampusAreas(force: force),
    ]);
  }

  Future<void> _loadHomeCampusAreas({bool force = false}) async {
    await Future.wait(_campus.venues
        .map((venue) => _loadHomeVenueAreas(venue, force: force)));
  }

  Future<void> _loadHomeCache() async {
    if (_homeCacheLoading || _homeCacheLoaded) return;
    _homeCacheLoading = true;
    final revision = _homeRecordsRevision;
    final historyRevision = _historyRecordsRevision;
    String? studentId;
    var cached = <Map<String, dynamic>>[];
    try {
      studentId = await AcademicAccountStore().loadStudentId();
      if (studentId != null) cached = await _bookingCache.load(studentId);
    } on Object {
      // The live refresh remains usable when local storage is unavailable.
    }
    _homeCacheLoading = false;
    if (!mounted) return;
    _cacheStudentId = studentId ?? _cacheStudentId;
    setState(() {
      _homeCacheLoaded = true;
      if (revision == _homeRecordsRevision) {
        _homeRecent = _activeHomeRecords(cached);
      } else {
        final unrefreshed = _activeHomeRecords(cached).where(
            (item) => !_homeRefreshedRoomTypes.contains(item['roomType']));
        _homeRecent = _mergeBookingRecords(unrefreshed, _homeRecent);
      }
      _cachedHistory = historyRevision == _historyRecordsRevision
          ? _mergeBookingRecords(cached, const [])
          : _mergeBookingRecords(cached, _cachedHistory);
    });
  }

  Future<void> _reloadHistoryCache() async {
    final revision = _homeRecordsRevision;
    String? studentId;
    var cached = <Map<String, dynamic>>[];
    try {
      studentId = await AcademicAccountStore().loadStudentId();
      if (studentId != null) cached = await _bookingCache.load(studentId);
    } on Object {
      // Online history remains usable when local storage is unavailable.
    }
    if (!mounted) return;
    _cacheStudentId = studentId ?? _cacheStudentId;
    setState(() {
      _homeCacheLoaded = true;
      final cachedHome = _activeHomeRecords(cached);
      _homeRecent = revision == _homeRecordsRevision
          ? _mergeBookingRecords(cachedHome, _homeRecent)
          : _mergeBookingRecords(
              cachedHome.where((item) =>
                  !_homeRefreshedRoomTypes.contains(item['roomType'])),
              _homeRecent);
      _cachedHistory = _mergeBookingRecords(cached, _cachedHistory);
    });
  }

  List<Map<String, dynamic>> _activeHomeRecords(
      Iterable<Map<String, dynamic>> records) {
    final byId = <String, Map<String, dynamic>>{};
    for (final item in records) {
      final id = ThereBookingClient.string(item['id']);
      final category = LibraryBookingRecord.category(item, _schoolNow);
      if (id != null && (category == '待履约' || category == '进行中')) {
        byId[id] = item;
      }
    }
    final result = byId.values.toList()
      ..sort((a, b) => (ThereBookingClient.string(b['beginTime']) ?? '')
          .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
    return result;
  }

  List<Map<String, dynamic>> _mergeBookingRecords(
      Iterable<Map<String, dynamic>> existing,
      Iterable<Map<String, dynamic>> updates) {
    final byId = <String, Map<String, dynamic>>{};
    for (final item in existing) {
      final id = ThereBookingClient.string(item['id']);
      if (id != null) byId[id] = item;
    }
    for (final item in updates) {
      final id = ThereBookingClient.string(item['id']);
      if (id != null) byId[id] = item;
    }
    return byId.values.toList()
      ..sort((a, b) => (ThereBookingClient.string(b['beginTime']) ?? '')
          .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
  }

  List<Map<String, dynamic>> _bookingHistory() =>
      _mergeBookingRecords(_cachedHistory, _recent);

  void _enqueueBookingCacheWrite(
      Future<void> Function(String studentId) write) {
    final pending = _bookingCacheWriteQueue.then((_) async {
      final studentId =
          _cacheStudentId ?? await AcademicAccountStore().loadStudentId();
      if (studentId == null) return;
      _cacheStudentId = studentId;
      await write(studentId);
    });
    _bookingCacheWriteQueue = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
  }

  void _cacheRecentForVenue(
      BookingVenue venue, List<Map<String, dynamic>> recent) {
    final confirmed = recent.where((item) {
      if (item['roomType'] != venue.roomType) return false;
      final id = ThereBookingClient.string(item['id']);
      final expectsFinish = id == null ? null : _awaitingWriteStatus[id];
      return expectsFinish == null ||
          _writeStatusConfirmed(item, expectsFinish);
    }).toList();
    final active = _activeHomeRecords(confirmed);
    _homeRecordsRevision++;
    _historyRecordsRevision++;
    _homeRefreshedRoomTypes.add(venue.roomType);
    if (mounted) {
      setState(() {
        _homeRecent.removeWhere((item) => item['roomType'] == venue.roomType);
        _homeRecent.addAll(active);
        _homeRecent.sort((a, b) =>
            (ThereBookingClient.string(b['beginTime']) ?? '')
                .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
        _cachedHistory = _mergeBookingRecords(_cachedHistory, confirmed);
      });
    }
    _enqueueBookingCacheWrite((studentId) =>
        _bookingCache.mergeVenue(studentId, venue.roomType, confirmed));
  }

  void _goBack() {
    if (_busy) return;
    switch (_step) {
      case _BookingStep.venue:
        Navigator.of(context).maybePop();
      case _BookingStep.area:
        _setStep(_BookingStep.venue);
      case _BookingStep.viewVenues:
        _viewOnly = false;
        _setStep(_BookingStep.venue);
      case _BookingStep.allAreas:
        _setStep(_BookingStep.viewVenues);
      case _BookingStep.time:
        _setStep(_viewOnly
            ? _BookingStep.allAreas
            : _areaSelectionFromHome
                ? _BookingStep.venue
                : _BookingStep.area);
      case _BookingStep.seat:
        _seatSelectionDraftId = null;
        _setStep(_BookingStep.time);
      case _BookingStep.bookings:
        _setStep(_BookingStep.venue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seatStep = _step == _BookingStep.seat;
    final enteringStep = _step;
    final slideForward = _slideForward;
    return PopScope(
      canPop: _step == _BookingStep.venue && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: ClipRect(
          child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) {
          final incoming = child.key == ValueKey(enteringStep);
          final begin = incoming
              ? Offset(slideForward ? 1 : -1, 0)
              : Offset(slideForward ? -1 : 1, 0);
          return SlideTransition(
            position: Tween<Offset>(begin: begin, end: Offset.zero)
                .animate(animation),
            child: child,
          );
        },
        child: ShuYoRouteSurface(
          key: ValueKey(_step),
          child: Scaffold(
            appBar: AppBar(
              leading: _step == _BookingStep.venue
                  ? null
                  : IconButton(
                      tooltip: '返回上一步',
                      onPressed: _busy ? null : _goBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
              title: Text(_pageTitle),
            ),
            body: _loading
                ? _loadingBody()
                : _error != null
                    ? EmptyState(
                        icon: _error!.contains('校园网')
                            ? Icons.wifi_off_outlined
                            : Icons.event_busy_outlined,
                        title: '加载失败',
                        message: _error!,
                        action: TextButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      )
                    : _stepBody(),
            bottomNavigationBar: seatStep && !_loading && _error == null
                ? _seatBottomBar()
                : null,
          ),
        ),
      )),
    );
  }

  String get _pageTitle => switch (_step) {
        _BookingStep.venue => '图书馆预约',
        _BookingStep.area => LibraryBookingNames.venue(_venue),
        _BookingStep.viewVenues => '选择场馆',
        _BookingStep.allAreas => '查看座位情况',
        _BookingStep.time => '创建预约',
        _BookingStep.seat => _viewOnly ? '查看座位情况' : '选择座位',
        _BookingStep.bookings => '我的预约',
      };

  Widget _loadingBody() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(_loadingLabel, textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _stepBody() => switch (_step) {
        _BookingStep.venue => _venuePage(),
        _BookingStep.area => _areaPage(),
        _BookingStep.viewVenues => _viewVenueSelectionPage(),
        _BookingStep.allAreas => _allAreasPage(),
        _BookingStep.time => _timePage(),
        _BookingStep.seat => _seatPage(),
        _BookingStep.bookings => _bookingsPage(),
      };

  Widget _surface({required Widget child, EdgeInsetsGeometry? padding}) {
    final colors = context.shuyoColors;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(18),
        child: child,
      ),
    );
  }

  Widget _pageList(List<Widget> children, {bool refreshable = false}) =>
      ListView(
        physics: refreshable ? const AlwaysScrollableScrollPhysics() : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: children,
      );

  Widget _infoLink(String label, VoidCallback onTap,
          {IconData icon = Icons.help_outline}) =>
      Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: context.shuyoColors.accent),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                    color: context.shuyoColors.accent,
                    fontSize: 14.5,
                    height: 1.25,
                    fontWeight: FontWeight.w400,
                  )),
            ]),
          ),
        ),
      );

  void _openInfo(String title, String asset) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ShuYoRouteSurface(
        child: LibraryBookingInfoPage(title: title, asset: asset),
      ),
    ));
  }

  void _showSeatsMap() =>
      unawaited(showLibraryBookingImage(context, librarySeatsAsset));

  Widget _selectionTabBar({
    required List<String> labels,
    required int selectedIndex,
    required ValueChanged<int> onTap,
    bool isScrollable = false,
  }) =>
      DefaultTabController(
        length: labels.length,
        initialIndex: selectedIndex,
        child: TabBar(
          isScrollable: isScrollable,
          labelPadding: isScrollable
              ? const EdgeInsets.symmetric(horizontal: 14)
              : EdgeInsets.zero,
          tabs: [
            for (final label in labels) Tab(text: label),
          ],
          onTap: onTap,
        ),
      );

  void _selectCampus(int index) {
    final campus = _BookingCampus.values[index];
    if (campus == _campus) return;
    setState(() => _campus = campus);
    if (_step == _BookingStep.venue) unawaited(_loadHomeCampusAreas());
  }

  Widget _campusBar() => _selectionTabBar(
        labels: [for (final campus in _BookingCampus.values) campus.label],
        selectedIndex: _campus.index,
        onTap: _selectCampus,
      );

  Widget _venuePage() => RefreshIndicator(
        key: const ValueKey('booking-home-refresh'),
        onRefresh: () async {
          if (!_busy) await _refreshHomeData(force: true);
        },
        child: _pageList([
          _homeRecentSection(),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
                child: Text('选择场馆',
                    style: Theme.of(context).textTheme.titleLarge)),
            _infoLink('使用规则', () => _openInfo('使用规则', libraryRulesAsset)),
          ]),
          const SizedBox(height: 16),
          _campusBar(),
          const SizedBox(height: 16),
          for (final (index, venue) in _campus.venues.indexed) ...[
            if (index > 0)
              Divider(height: 1, color: context.shuyoColors.border),
            ListTile(
              key: ValueKey('home-venue-${venue.name}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Row(children: [
                Flexible(
                  child: Text(LibraryBookingNames.venue(venue),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (!_loadingHomeAreas.contains(venue))
                  if (_homeAreasByVenue[venue]
                      case final List<Map<String, dynamic>> areas) ...[
                    const SizedBox(width: 8),
                    Text('${_selectableAreas(areas).length}分区',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: context.shuyoColors.textTertiary)),
                  ],
              ]),
              trailing: _loadingHomeAreas.contains(venue)
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_expandedVenues.contains(venue)
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down),
              onTap: () => _toggleHomeVenue(venue),
              // The old area step remains available in the page state, but the
              // venue row now expands its areas directly on this screen.
              // onTap: () { setState(() => _venue = venue); unawaited(_loadVenue()); },
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              alignment: Alignment.topCenter,
              curve: Curves.easeOutCubic,
              child: _expandedVenues.contains(venue)
                  ? _homeVenueAreas(venue)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ], refreshable: true),
      );

  Widget _homeVenueAreas(BookingVenue venue) {
    final areas = _homeAreasByVenue[venue];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_homeAreaErrors.containsKey(venue) && areas == null)
          TextButton.icon(
            onPressed: _loadingHomeAreas.contains(venue)
                ? null
                : () => unawaited(
                    _loadHomeVenueAreas(venue, interactiveAuth: true)),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('分区暂时无法加载，重试'),
          )
        else if (areas != null && _selectableAreas(areas).isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('当前场馆没有可选分区'),
          )
        else if (areas != null)
          for (final area in _selectableAreas(areas)) ...[
            _areaCard(venue, area, areas, embedded: true),
            Divider(height: 1, color: context.shuyoColors.border),
          ],
        if (venue == BookingVenue.studySpace) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 8, children: [
            _infoLink('座位分布', _showSeatsMap, icon: Icons.map_outlined),
            _infoLink('常见问题', () => _openInfo('常见问题', libraryQaAsset)),
          ]),
        ],
      ]),
    );
  }

  Widget _homeRecentSection() {
    final colors = context.shuyoColors;
    final booking = _homeActiveBookings().firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 16, 8),
        child: Text('我的预约', style: Theme.of(context).textTheme.titleLarge),
      ),
      ConstrainedBox(
        key: const ValueKey('home-bookings-viewport'),
        constraints: BoxConstraints(minHeight: _homeBookingsMinHeight()),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (booking == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                    _bookingsLoading || !_homeCacheLoaded
                        ? '加载中'
                        : _bookingsIncomplete
                            ? '预约列表暂时无法完整加载，请检查是否连接校园网'
                            : '暂无待履约或进行中的预约',
                    style: TextStyle(color: colors.textTertiary)),
              ),
            if (!_bookingsLoading && booking != null && _bookingsIncomplete)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('部分预约状态暂时无法更新',
                    style: TextStyle(color: colors.textTertiary)),
              ),
            if (booking != null)
              _bookingTile(booking, 0,
                  key: ValueKey<String>(
                      'home:${ThereBookingClient.string(booking['id'])}')),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _openBookings,
          style: TextButton.styleFrom(foregroundColor: colors.textSecondary),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('查看历史预约'),
              SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    ]);
  }

  double _homeBookingsMinHeight() {
    final theme = Theme.of(context).textTheme;
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(
            text: '预约', style: DefaultTextStyle.of(context).style.merge(style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    // Reserve one typical row while allowing wrapped content to grow.
    final rowHeight = 32 +
        7 +
        8 +
        lineHeight(theme.titleMedium) +
        2 * lineHeight(theme.bodySmall);
    return rowHeight;
  }

  Widget _bookingTile(Map<String, dynamic> item, int index,
      {required Key key}) {
    final id = ThereBookingClient.string(item['id']);
    final schoolNow = _schoolNow;
    final venueName = LibraryBookingRecord.venueName(item);
    final venue = BookingVenue.values
        .where((itemVenue) => itemVenue.roomType == item['roomType'])
        .firstOrNull;
    final areaName = LibraryBookingNames.area(
      venue,
      ThereBookingClient.string(item['officeAreaName']) ?? venueName,
    );
    return LibraryBookingListTile(
      key: key,
      index: index,
      title: '${ThereBookingClient.string(item['roomName']) ?? '座位'} · '
          '$areaName',
      venueName: venue == null ? venueName : _BookingCampus.venueLabel(venue),
      status: LibraryBookingRecord.category(item, schoolNow),
      timeRange: LibraryBookingRecord.displayTimeRange(
          item['beginTime'], item['endTime'], schoolNow),
      onTap: id == null ? null : () => _openDetail(item),
    );
  }

  List<Map<String, dynamic>> _homeActiveBookings() {
    final byId = <String, Map<String, dynamic>>{};
    for (final item in _homeRecent) {
      final id = ThereBookingClient.string(item['id']);
      if (id != null) byId[id] = item;
    }
    for (final item in _recent) {
      final id = ThereBookingClient.string(item['id']);
      if (id != null) byId[id] = item;
    }
    final schoolNow = _schoolNow;
    final records = byId.values.where((item) {
      final category = LibraryBookingRecord.category(item, schoolNow);
      return category == '待履约' || category == '进行中';
    }).toList();
    records.sort((a, b) => (ThereBookingClient.string(b['beginTime']) ?? '')
        .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
    return records;
  }

  List<Map<String, dynamic>> _areasForVenue(
          List<Map<String, dynamic>> areas, BookingVenue venue) =>
      areas
          .where((area) => ThereBookingClient.strings(area['supportRoomTypes'])
              .contains(venue.roomType))
          .toList();

  Future<void> _loadHomeVenueAreas(BookingVenue venue,
      {bool interactiveAuth = false, bool force = false}) {
    final pending = _homeAreaLoads[venue];
    if (pending != null) return pending;
    if (!mounted || !force && _isFresh(_homeAreasUpdatedAt[venue])) {
      return Future<void>.value();
    }
    if (force && venue.isChaoxing && !_sharedChaoxingRoomLoadPending) {
      _sharedChaoxingRoomLoad = null;
      _sharedChaoxingRoomLoadAt = null;
    }
    late final Future<void> load;
    load = _fetchHomeVenueAreas(venue, interactiveAuth: interactiveAuth)
        .whenComplete(() {
      if (identical(_homeAreaLoads[venue], load)) _homeAreaLoads.remove(venue);
    });
    _homeAreaLoads[venue] = load;
    return load;
  }

  Future<void> _fetchHomeVenueAreas(BookingVenue venue,
      {required bool interactiveAuth}) async {
    final generation = (_homeAreaGenerations[venue] ?? 0) + 1;
    _homeAreaGenerations[venue] = generation;
    _homeAreasUpdatedAt.remove(venue);
    setState(() {
      if (!_homeAreasByVenue.containsKey(venue)) _loadingHomeAreas.add(venue);
      _homeAreaErrors.remove(venue);
    });
    final client = _clientForVenue(venue);
    try {
      final request = () async {
        final profile = await _read(() async {
          if (interactiveAuth && !venue.isChaoxing) {
            await _selectBookingVenue(venue, refresh: true);
          } else {
            await _ensureVenueSelected(venue, client);
          }
          return client.profile();
        }, venue: venue, client: client, interactiveAuth: interactiveAuth);
        await _checkAccount(profile, client: client);
        return _read(() => client.areas(_clockDay),
            venue: venue, client: client, interactiveAuth: interactiveAuth);
      }();
      final areas = await (interactiveAuth
          ? request
          : request.timeout(const Duration(seconds: 15)));
      if (!mounted || _homeAreaGenerations[venue] != generation) return;
      final supported = _areasForVenue(areas, venue);
      if (!venue.isChaoxing && supported.isEmpty) {
        throw const ThereBookingException(
          ThereFailureKind.uncertain,
          '分区列表暂时不可用',
        );
      }
      setState(() {
        _homeAreasByVenue[venue] = supported;
        _homeAreasUpdatedAt[venue] = _schoolNow;
        _loadingHomeAreas.remove(venue);
      });
    } on Object {
      if (!mounted || _homeAreaGenerations[venue] != generation) return;
      setState(() {
        _loadingHomeAreas.remove(venue);
        _homeAreaErrors[venue] = '分区暂时无法加载';
      });
    }
  }

  void _toggleHomeVenue(BookingVenue venue) {
    final expand = !_expandedVenues.contains(venue);
    setState(() {
      if (expand) {
        _expandedVenues.add(venue);
      } else {
        _expandedVenues.remove(venue);
      }
    });
    if (expand) {
      unawaited(_loadHomeVenueAreas(venue, interactiveAuth: true));
    }
  }

  bool _writeStatusConfirmed(Map<String, dynamic> item, bool expectsFinish) {
    final status =
        (ThereBookingClient.string(item['status']) ?? '').toUpperCase();
    if (expectsFinish) {
      return LibraryBookingRecord.finishedEarly(item) ||
          status == 'CX_2' ||
          status == 'CX_7' ||
          (status.startsWith('CX_') && item['cxCurrent'] == false);
    }
    return status == 'CANCEL' ||
        (ThereBookingClient.string(item['statusLabel']) ?? '').contains('取消');
  }

  void _removeBookingFromRecent(String bookingId) {
    if (!mounted) return;
    final removed = [..._homeRecent, ..._recent, ..._cachedHistory]
        .where((item) => ThereBookingClient.string(item['id']) == bookingId)
        .firstOrNull;
    final roomType = ThereBookingClient.string(removed?['roomType']);
    if (roomType != null) _homeRefreshedRoomTypes.add(roomType);
    setState(() {
      _recent.removeWhere(
          (item) => ThereBookingClient.string(item['id']) == bookingId);
      _homeRecent.removeWhere(
          (item) => ThereBookingClient.string(item['id']) == bookingId);
      _prefetchedDetails.remove(bookingId);
    });
    _homeRecordsRevision++;
  }

  Widget _viewVenueSelectionPage() {
    final selected = _viewVenueSelection;
    return _pageList([
      Text('选择要查看的场馆', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      _campusBar(),
      const SizedBox(height: 16),
      for (final venue in _campus.venues) ...[
        _surface(
          padding: EdgeInsets.zero,
          child: CheckboxListTile(
            key: ValueKey('view-${venue.name}'),
            title: Text(LibraryBookingNames.venue(venue)),
            value: selected.contains(venue),
            controlAffinity: ListTileControlAffinity.trailing,
            onChanged: (value) => setState(() {
              if (value == true) {
                selected.add(venue);
              } else {
                selected.remove(venue);
              }
            }),
          ),
        ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 8),
      FilledButton(
        onPressed: selected.isEmpty ? null : () => unawaited(_loadAllAreas()),
        child: const Text('下一步'),
      ),
    ]);
  }

  Widget _areaPage() {
    final selectable = _selectableAreas(_areas);
    return _pageList([
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(
            flex: 1,
            child: Text('选择分区',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge)),
        if (_venue == BookingVenue.studySpace)
          Flexible(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _infoLink('座位分布', _showSeatsMap, icon: Icons.map_outlined),
                  _infoLink('常见问题', () => _openInfo('常见问题', libraryQaAsset)),
                ]),
              )),
      ]),
      const SizedBox(height: 16),
      if (selectable.isEmpty) const Text('当前场馆没有可选分区'),
      for (final area in selectable) ...[
        _areaCard(_venue, area, _areas),
        const SizedBox(height: 10),
      ],
    ]);
  }

  Widget _allAreasPage() => _pageList([
        if (!_loadingAllAreas &&
            _allAreasByVenue.values
                .every((areas) => _selectableAreas(areas).isEmpty))
          const Text('暂无可查看的分区'),
        for (final venue in BookingVenue.values)
          if (_viewVenueSelection.contains(venue))
            if (_allAreasByVenue[venue]
                case final List<Map<String, dynamic>> areas) ...[
              Text(LibraryBookingNames.venue(venue),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              for (final area in _selectableAreas(areas)) ...[
                _areaCard(venue, area, areas),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
            ],
        if (_loadingAllAreas) ...[
          const SizedBox(height: 10),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          const Center(child: Text('正在加载其他场馆的分区')),
        ],
        if (_allAreasError != null) ...[
          Text(_allAreasError!),
          TextButton.icon(
            onPressed:
                _loadingAllAreas ? null : () => unawaited(_loadAllAreas()),
            icon: const Icon(Icons.refresh),
            label: const Text('重试加载场馆'),
          ),
        ],
      ]);

  List<Map<String, dynamic>> _selectableAreas(
      List<Map<String, dynamic>> areas) {
    final parentIds = areas
        .map((area) => ThereBookingClient.string(area['parentId']))
        .whereType<String>()
        .toSet();
    // Directory nodes can use the same level value as selectable areas.
    final leaves = areas
        .where((area) =>
            !parentIds.contains(ThereBookingClient.string(area['id'])))
        .toList();
    return leaves.isEmpty ? areas : leaves;
  }

  Widget _areaCard(BookingVenue venue, Map<String, dynamic> area,
      List<Map<String, dynamic>> areas,
      {bool embedded = false}) {
    final content = InkWell(
      onTap: _step == _BookingStep.allAreas && _loadingAllAreas
          ? null
          : () {
              setState(() {
                _slideForward = true;
                _venue = venue;
                _areaSelectionFromHome = embedded;
                if (embedded) _viewOnly = false;
                _areas = areas;
                _selectedArea = area;
                _rooms = [];
                _selectedRoomId = null;
                _step = _BookingStep.time;
                _day = _clockDay;
                _days = [];
                _prefetchedDays.clear();
                _dayRuleErrors.clear();
                _areaData = null;
                _areaRulesError = null;
                _loadingAreaRules = false;
                _loadingAllAreas = false;
                _clearPreview();
              });
              unawaited(_loadDays());
            },
      child: Padding(
        padding: embedded
            ? const EdgeInsets.fromLTRB(4, 12, 8, 14)
            : const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _areaName(venue, area, areas: areas),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _openingHours(area),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: context.shuyoColors.textTertiary,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _areaStats(area),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
    return embedded
        ? content
        : _surface(padding: EdgeInsets.zero, child: content);
  }

  Widget _areaStats(Map<String, dynamic> area) {
    final open =
        _areaCount(area, 'totalResourceCount', 'disabledResourceCount');
    final base = Theme.of(context).textTheme.bodyMedium;
    final accent = context.shuyoColors.accent;
    final free = area['freeResourceCount'];
    if (free is num) {
      return Text.rich(TextSpan(style: base, children: [
        const TextSpan(text: '开放座位数：'),
        TextSpan(
            text: free.toInt().toString(),
            style: base?.copyWith(color: accent)),
        TextSpan(text: '/$open'),
      ]));
    }
    return Text('开放座位数：$open', style: base);
  }

  Widget _seatStats(int available, int total) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return Text.rich(TextSpan(style: base, children: [
      const TextSpan(text: '可选座位数：'),
      TextSpan(
          text: '$available',
          style: base?.copyWith(color: context.shuyoColors.accent)),
      TextSpan(text: '/$total'),
    ]));
  }

  String get _selectedAreaPath {
    final campus = _BookingCampus.values
        .where((item) => item.venues.contains(_venue))
        .firstOrNull;
    return [
      if (campus != null) campus.label,
      LibraryBookingNames.venue(_venue),
      _areaName(_venue, _selectedArea ?? const {}),
    ].join(' - ');
  }

  String _areaName(BookingVenue venue, Map<String, dynamic> area,
      {List<Map<String, dynamic>>? areas}) {
    final parentId = ThereBookingClient.string(area['parentId']);
    final parent =
        (areas ?? _areas).where((item) => item['id'] == parentId).firstOrNull;
    final name = ThereBookingClient.string(area['name']) ?? '未命名分区';
    final parentName = ThereBookingClient.string(parent?['name']);
    final systemName = parentName == null ? name : '$parentName - $name';
    return LibraryBookingNames.area(venue, systemName);
  }

  String _areaCount(
      Map<String, dynamic> area, String totalKey, String disabledKey) {
    final total = area[totalKey];
    final disabled = area[disabledKey];
    if (total is! num) return '—';
    return (total - (disabled is num ? disabled : 0)).toInt().toString();
  }

  String _openingHours(Map<String, dynamic> area) {
    final rules = ThereBookingClient.object(area['bookingTimes']) ?? const {};
    final start = rules['startHour'];
    final end = rules['endHour'];
    if (start is! num || end is! num) return '以分区规则为准';
    return '${start.toInt().toString().padLeft(2, '0')}:00–${end.toInt().toString().padLeft(2, '0')}:00';
  }

  void _selectDay(String day) {
    if (day == _day) return;
    setState(() => _showPrefetchedDay(day));
  }

  void _showPrefetchedDay(String day) {
    _day = day;
    _timeRangeDragging = false;
    _rooms = [];
    _selectedRoomId = null;
    _loadingAreaRules = false;
    _clearPreview();
    final cached = _prefetchedDays[day];
    if (cached == null) {
      _areaData = null;
      _start = '';
      _end = '';
      _areaRulesError = _dayRuleErrors[day] ?? '该日期的预约时段暂时不可用';
      return;
    }
    _areaRulesError = null;
    _areaData = cached.areaData;
    _effectiveMinMinutes = cached.minMinutes;
    _start = cached.start;
    _end = cached.end;
    _previewAvailable = cached.available;
    _previewRooms = cached.rooms;
    _previewError = cached.previewError;
    if (cached.available != null) _previewKey = _currentPreviewKey;
  }

  String _monthDay(String day) {
    final date = DateTime.tryParse(day);
    return date == null ? day : '${date.month}月${date.day}日';
  }

  Widget _timePage() {
    final rules =
        ThereBookingClient.object(_areaData?['bookingTimes']) ?? const {};
    final choices = _timeChoices(rules);
    final hasInterval = _isValidInterval(_start, _end, rules);
    final sliderChoices = choices
        .where((value) => _minutes(value) >= 0 && _minutes(value) % 30 == 0)
        .toList();
    final showTimeSlider = hasInterval &&
        sliderChoices.length > 1 &&
        sliderChoices.contains(_start) &&
        sliderChoices.contains(_end);
    final sliderMin = sliderChoices.isEmpty ? 0 : _minutes(sliderChoices.first);
    final sliderMax = sliderChoices.isEmpty ? 0 : _minutes(sliderChoices.last);
    final firstAllowedSliderStart =
        _eligibleTimes(sliderChoices, rules, start: true).firstOrNull;
    final pastTimeFraction = _day == _clockDay &&
            sliderMax > sliderMin &&
            firstAllowedSliderStart != null
        ? ((_minutes(firstAllowedSliderStart) - sliderMin) /
                (sliderMax - sliderMin))
            .clamp(0.0, 1.0)
        : 0.0;
    final colors = context.shuyoColors;
    final selectedPreviewRoomName =
        ThereBookingClient.string(_selectedPreviewRoom?['name']) ??
            ThereBookingClient.string(_selectedPreviewRoom?['id']);
    final max = rules['maxDuration'];
    final firstDate = DateTime.parse(_clockDay);
    final calendarDays = [
      for (var offset = 0; offset < 5; offset++)
        DateTime.utc(firstDate.year, firstDate.month, firstDate.day + offset),
    ];
    String dayKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return _pageList([
      Text('已选场馆', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(_selectedAreaPath, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 18),
      Text('选择日期', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Row(children: [
        for (final date in calendarDays) ...[
          if (date != calendarDays.first) const SizedBox(width: 4),
          Expanded(
            child: Builder(builder: (context) {
              final day = dayKey(date);
              final enabled = _days.contains(day);
              final selected = enabled && day == _day;
              return Semantics(
                label: '${_monthDay(day)}，周${weekdays[date.weekday - 1]}'
                    '${enabled ? '' : '，不可预约'}',
                button: true,
                selected: selected,
                enabled: enabled,
                child: Material(
                  color: selected
                      ? colors.accentSoft
                      : enabled
                          ? colors.surface
                          : colors.disabledFill,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    key: ValueKey('booking-day-$day'),
                    onTap: enabled ? () => _selectDay(day) : null,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      height: 76,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: selected ? colors.accent : colors.border),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('周${weekdays[date.weekday - 1]}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: enabled
                                      ? colors.textSecondary
                                      : colors.textMuted)),
                          const SizedBox(height: 3),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('${date.month}/${date.day}',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: enabled
                                        ? selected
                                            ? colors.accent
                                            : colors.textPrimary
                                        : colors.textMuted)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ]),
      if (_days.isEmpty) ...[
        const SizedBox(height: 8),
        const Text('暂无可选日期，请稍后刷新'),
      ],
      const SizedBox(height: 22),
      Text('选择时段', style: Theme.of(context).textTheme.titleMedium),
      if (_loadingAreaRules && _areaData == null) ...[
        const SizedBox(height: 22),
        const Center(child: CircularProgressIndicator()),
      ] else if (_areaRulesError != null && _areaData == null) ...[
        const SizedBox(height: 18),
        Text(_areaRulesError!),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => unawaited(_loadAreaRules()),
          icon: const Icon(Icons.refresh),
          label: const Text('重试加载时段'),
        ),
      ] else if (_days.isNotEmpty) ...[
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(max is num ? '最长 ${_durationText(max.toInt())}' : '',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textTertiary,
                    )),
          ),
          Expanded(
            child: Text(
                hasInterval
                    ? '已选 ${_durationText(_minutes(_end) - _minutes(_start))}'
                    : '',
                textAlign: TextAlign.start,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textTertiary,
                    )),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _timePair('开始', _start, choices, rules, start: true)),
          const SizedBox(width: 8),
          const Text('–', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Expanded(child: _timePair('结束', _end, choices, rules, start: false)),
        ]),
        if (showTimeSlider) ...[
          const SizedBox(height: 12),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              rangeTrackShape: _PastTimeRangeTrackShape(
                disabledFraction: pastTimeFraction,
                disabledColor: colors.textMuted,
              ),
              activeTrackColor: colors.accent,
              inactiveTrackColor: colors.accent.withValues(alpha: 0.45),
              thumbColor: colors.accent,
              rangeTickMarkShape:
                  const RoundRangeSliderTickMarkShape(tickMarkRadius: 0),
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: RangeSlider(
              key: const ValueKey('booking-time-range'),
              values: RangeValues(
                  _minutes(_start).toDouble(), _minutes(_end).toDouble()),
              min: sliderMin.toDouble(),
              max: sliderMax.toDouble(),
              divisions: (sliderMax - sliderMin) ~/ 30,
              onChanged: _loadingAreaRules || _areaRulesError != null
                  ? null
                  : (values) =>
                      _applySliderSelection(values, sliderChoices, rules),
              onChangeEnd: (_) => _finishSliderSelection(rules),
            ),
          ),
        ],
        if (!hasInterval && !_loadingAreaRules && _areaRulesError == null) ...[
          const SizedBox(height: 18),
          Text(_day == _clockDay
              ? _days.any((day) => day.compareTo(_day) > 0)
                  ? '今天已无可预约时段，请选择明天'
                  : '今天已无可预约时段'
              : '当前没有可选时段'),
        ],
        const SizedBox(height: 22),
        Text(_viewOnly ? '查看座位' : '选择座位',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 24,
          child: hasInterval &&
                  !_loadingAreaRules &&
                  !_timeRangeDragging &&
                  !_previewLoading &&
                  _previewAvailable != null &&
                  _previewKey == _currentPreviewKey
              ? _seatStats(_previewAvailable!, _previewRooms.length)
              : null,
        ),
        if (_previewError != null && !_timeRangeDragging) ...[
          Text(_previewError!, style: TextStyle(color: colors.danger)),
          TextButton.icon(
            onPressed:
                _previewLoading ? null : () => unawaited(_previewSeats()),
            icon: const Icon(Icons.refresh),
            label: const Text('重试查询座位'),
          ),
        ],
        if (_areaRulesError != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => unawaited(_loadAreaRules()),
            icon: const Icon(Icons.refresh),
            label: const Text('重试加载时段'),
          ),
        ],
        const SizedBox(height: 14),
        if (_viewOnly)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: hasInterval &&
                      !_loadingAreaRules &&
                      _areaRulesError == null &&
                      !_timeRangeDragging &&
                      !_previewLoading
                  ? _openSeatPage
                  : null,
              child: const Text('查看座位'),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('座位号',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.textTertiary)),
                    Text(
                      selectedPreviewRoomName ?? '——',
                      key: const ValueKey('selected-seat-label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontSize: 24,
                            color: selectedPreviewRoomName == null
                                ? colors.textMuted
                                : null,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: '手动选座',
                child: OutlinedButton.icon(
                  key: const ValueKey('manual-seat-button'),
                  onPressed: _canSelectSeat ? _openSeatPage : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.grid_view_outlined),
                  label: const Text('自选'),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '随机选座',
                child: OutlinedButton.icon(
                  key: const ValueKey('random-seat-button'),
                  onPressed: _canSelectSeat ? _selectRandomSeat : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.casino_outlined),
                  label: const Text('随机'),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  _canSelectSeat && _selectedPreviewRoom != null && !_busy
                      ? _createBooking
                      : null,
              child: const Text('创建预约'),
            ),
          ),
        ],
      ],
    ]);
  }

  Widget _timePair(String label, String value, List<String> choices,
      Map<String, dynamic> rules,
      {required bool start}) {
    final parts = value.split(':');
    final hour = parts.length == 2 ? parts[0] : '—';
    final minute = parts.length == 2 ? parts[1] : '—';
    final enabled = !_loadingAreaRules &&
        _areaRulesError == null &&
        _eligibleTimes(choices, rules, start: start).isNotEmpty;
    return Row(children: [
      Expanded(
          child: _timeBox('$label小时', hour, enabled,
              key: ValueKey(start ? 'start-hour' : 'end-hour'),
              onTap: () => _pickBookingTime(start, true, choices, rules))),
      const Padding(
          padding: EdgeInsets.symmetric(horizontal: 3),
          child: Text(':', style: TextStyle(fontSize: 22))),
      Expanded(
          child: _timeBox('$label分钟', minute, enabled,
              key: ValueKey(start ? 'start-minute' : 'end-minute'),
              onTap: () => _pickBookingTime(start, false, choices, rules))),
    ]);
  }

  Widget _timeBox(String label, String value, bool enabled,
      {required Key key, required VoidCallback onTap}) {
    final colors = context.shuyoColors;
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      child: Material(
        color: enabled ? colors.surface : colors.disabledFill,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: key,
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.borderStrong),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: _timeDigitFontSize,
                    fontWeight: FontWeight.w500,
                  )),
            ),
          ),
        ),
      ),
    );
  }

  List<String> _eligibleTimes(List<String> choices, Map<String, dynamic> rules,
          {required bool start}) =>
      [
        for (final value in choices)
          if (start
              ? choices.any((end) => _isValidInterval(value, end, rules))
              : choices.any((begin) => _isValidInterval(begin, value, rules)))
            value,
      ];

  Future<void> _pickBookingTime(bool start, bool focusHour,
      List<String> choices, Map<String, dynamic> rules) async {
    final eligible = _eligibleTimes(choices, rules, start: start);
    if (eligible.isEmpty) return;
    final current = start ? _start : _end;
    final initial = eligible.contains(current) ? current : eligible.first;
    var selectedHour = initial.substring(0, 2);
    var selectedMinute = initial.substring(3, 5);
    final hours =
        eligible.map((value) => value.substring(0, 2)).toSet().toList();
    final initialMinutes = eligible
        .where((value) => value.startsWith('$selectedHour:'))
        .map((value) => value.substring(3, 5))
        .toSet()
        .toList();
    final hourController =
        FixedExtentScrollController(initialItem: hours.indexOf(selectedHour));
    final minuteController = FixedExtentScrollController(
        initialItem: initialMinutes.indexOf(selectedMinute));
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.shuyoColors.surface,
      elevation: 0,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, updateSheet) {
          final minutes = eligible
              .where((value) => value.startsWith('$selectedHour:'))
              .map((value) => value.substring(3, 5))
              .toSet()
              .toList();
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(start ? '选择开始时间' : '选择结束时间',
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('$selectedHour:$selectedMinute',
                    style: Theme.of(sheetContext).textTheme.headlineSmall),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                      child: _timeWheel(
                    sheetContext,
                    '小时',
                    hours,
                    selected: selectedHour,
                    controller: hourController,
                    focused: focusHour,
                    onSelect: (index) {
                      final hour = hours[index];
                      if (hour == selectedHour) return;
                      updateSheet(() {
                        selectedHour = hour;
                        focusHour = true;
                        final available = eligible
                            .where((value) => value.startsWith('$hour:'))
                            .map((value) => value.substring(3, 5))
                            .toSet()
                            .toList();
                        if (!available.contains(selectedMinute)) {
                          selectedMinute = available.first;
                        }
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!minuteController.hasClients) return;
                        final available = eligible
                            .where((value) => value.startsWith('$hour:'))
                            .map((value) => value.substring(3, 5))
                            .toSet()
                            .toList();
                        minuteController
                            .jumpToItem(available.indexOf(selectedMinute));
                      });
                    },
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _timeWheel(
                    sheetContext,
                    '分钟',
                    minutes,
                    selected: selectedMinute,
                    controller: minuteController,
                    focused: !focusHour,
                    onSelect: (index) => updateSheet(() {
                      selectedMinute = minutes[index];
                      focusHour = false;
                    }),
                  )),
                ]),
                const SizedBox(height: 18),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                          sheetContext, '$selectedHour:$selectedMinute'),
                      child: const Text('确认时间'),
                    )),
              ]),
            ),
          );
        },
      ),
    );
    hourController.dispose();
    minuteController.dispose();
    if (picked == null || !mounted || _step != _BookingStep.time) return;
    final index = choices.indexOf(picked);
    if (index >= 0) _applyTimeSelection(start, index, choices, rules);
  }

  Widget _timeWheel(BuildContext context, String title, List<String> options,
      {required String selected,
      required FixedExtentScrollController controller,
      required bool focused,
      required ValueChanged<int> onSelect}) {
    final colors = context.shuyoColors;
    return Column(children: [
      Text(title,
          style:
              TextStyle(color: focused ? colors.accent : colors.textSecondary)),
      const SizedBox(height: 7),
      SizedBox(
          height: 220,
          child: CupertinoPicker(
            key: ValueKey('time-wheel-$title'),
            itemExtent: 44,
            scrollController: controller,
            backgroundColor: colors.surface,
            selectionOverlay: null,
            onSelectedItemChanged: onSelect,
            children: [
              for (final option in options)
                Center(
                    child: Text(option,
                        style: TextStyle(
                          color: option == selected
                              ? colors.accent
                              : colors.textPrimary,
                          fontWeight: option == selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ))),
            ],
          )),
    ]);
  }

  void _applyTimeSelection(bool start, int requested, List<String> choices,
      Map<String, dynamic> rules,
      {bool preview = true}) {
    final earliest = _earliestAllowedStart;
    bool valid(String begin, String end) =>
        _validIntervalAt(begin, end, rules, earliest, _effectiveMinMinutes);
    final candidates = <int>[
      for (var i = 0; i < choices.length; i++)
        if (start
            ? choices.any((end) => valid(choices[i], end))
            : choices.any((begin) => valid(begin, choices[i])))
          i,
    ];
    if (candidates.isEmpty) return;
    candidates
        .sort((a, b) => (a - requested).abs().compareTo((b - requested).abs()));
    final chosen = choices[candidates.first];
    final counterparts = choices
        .where((other) => start ? valid(chosen, other) : valid(other, chosen))
        .toList();
    if (counterparts.isEmpty) return;
    final previous = start ? _end : _start;
    counterparts.sort((a, b) => (_minutes(a) - _minutes(previous))
        .abs()
        .compareTo((_minutes(b) - _minutes(previous)).abs()));
    if (start
        ? chosen == _start && counterparts.first == _end
        : chosen == _end && counterparts.first == _start) {
      return;
    }
    setState(() {
      if (start) {
        _start = chosen;
        _end = counterparts.first;
      } else {
        _end = chosen;
        _start = counterparts.first;
      }
      if (preview) {
        _clearPreview();
      } else {
        _timeRangeDragging = true;
      }
    });
    if (preview && _isValidInterval(_start, _end, rules)) {
      unawaited(_previewSeats());
    }
  }

  void _applySliderSelection(RangeValues values, List<String> sliderChoices,
      Map<String, dynamic> rules) {
    final startChange = (values.start - _minutes(_start)).abs();
    final endChange = (values.end - _minutes(_end)).abs();
    if (startChange == 0 && endChange == 0) return;
    final start = startChange >= endChange;
    final target = start ? values.start : values.end;
    var requested = 0;
    for (var i = 1; i < sliderChoices.length; i++) {
      if ((_minutes(sliderChoices[i]) - target).abs() <
          (_minutes(sliderChoices[requested]) - target).abs()) {
        requested = i;
      }
    }
    _applyTimeSelection(start, requested, sliderChoices, rules, preview: false);
  }

  void _finishSliderSelection(Map<String, dynamic> rules) {
    final shouldRefresh = _previewKey != _currentPreviewKey;
    setState(() {
      _timeRangeDragging = false;
      if (shouldRefresh) _clearPreview();
    });
    if (shouldRefresh && _isValidInterval(_start, _end, rules)) {
      unawaited(_previewSeats());
    }
  }

  String get _currentPreviewKey =>
      '${_venue.roomType}|${ThereBookingClient.string(_selectedArea?['id'])}|$_day|$_start|$_end';

  bool get _canSelectSeat {
    final rules =
        ThereBookingClient.object(_areaData?['bookingTimes']) ?? const {};
    return !_busy &&
        !_loadingAreaRules &&
        _areaRulesError == null &&
        !_timeRangeDragging &&
        !_previewLoading &&
        _previewError == null &&
        _previewKey == _currentPreviewKey &&
        _isValidInterval(_start, _end, rules) &&
        _previewRooms.any((room) =>
            _isBookable(room) && ThereBookingClient.string(room['id']) != null);
  }

  Map<String, dynamic>? get _selectedPreviewRoom => _previewRooms
      .where((room) => room['id'] == _selectedRoomId && _isBookable(room))
      .firstOrNull;

  void _openSeatPage() {
    setState(() {
      _slideForward = true;
      _seatSelectionDraftId = _selectedRoomId;
      _step = _BookingStep.seat;
    });
    unawaited(_refreshSeats());
  }

  void _selectRandomSeat() {
    if (!_canSelectSeat) return;
    final available = _previewRooms
        .where((room) =>
            _isBookable(room) && ThereBookingClient.string(room['id']) != null)
        .toList();
    setState(() => _selectedRoomId = ThereBookingClient.string(
        available[Random().nextInt(available.length)]['id']));
  }

  void _confirmSeatSelection() {
    final room = _rooms
        .where(
            (item) => item['id'] == _seatSelectionDraftId && _isBookable(item))
        .firstOrNull;
    if (room == null) return;
    setState(() {
      _selectedRoomId = ThereBookingClient.string(room['id']);
      _seatSelectionDraftId = null;
      _previewRooms = _rooms;
      _previewAvailable = _rooms.where(_isBookable).length;
      _previewKey = _currentPreviewKey;
      _slideForward = false;
      _step = _BookingStep.time;
    });
  }

  void _clearPreview() {
    ++_previewGeneration;
    _previewAvailable = null;
    _previewRooms = [];
    _previewError = null;
    _previewKey = null;
    _previewLoading = false;
    _selectedRoomId = null;
  }

  Future<void> _previewSeats() async {
    final id = ThereBookingClient.string(_selectedArea?['id']);
    final rules =
        ThereBookingClient.object(_areaData?['bookingTimes']) ?? const {};
    if (id == null ||
        _timeRangeDragging ||
        _previewLoading ||
        !_isValidInterval(_start, _end, rules)) {
      return;
    }
    final key = _currentPreviewKey;
    final previewGeneration = _previewGeneration;
    final day = _day;
    final start = _start;
    final end = _end;
    final venue = _venue;
    final client = _clientForVenue(venue);
    setState(() {
      _previewLoading = true;
      _previewError = null;
      _previewAvailable = null;
    });
    try {
      final data = await _read(() async {
        await _selectBookingVenue(venue);
        return client.area(id, '$day $start', '$day $end');
      }, venue: venue, client: client);
      if (!mounted ||
          _step != _BookingStep.time ||
          previewGeneration != _previewGeneration ||
          key != _currentPreviewKey) {
        return;
      }
      setState(() {
        _previewRooms = ThereBookingClient.objects(data['rooms']);
        _previewAvailable = _previewRooms.where(_isBookable).length;
        _previewKey = key;
        _previewLoading = false;
      });
    } on Object catch (error) {
      if (!mounted ||
          _step != _BookingStep.time ||
          previewGeneration != _previewGeneration ||
          key != _currentPreviewKey) {
        return;
      }
      setState(() {
        _previewError = _friendlyError(error);
        _previewLoading = false;
      });
    }
  }

  int _minutes(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return -1;
    return (int.tryParse(parts[0]) ?? -1) * 60 + (int.tryParse(parts[1]) ?? 0);
  }

  String _durationText(int minutes) {
    final hours =
        (minutes / 60).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$hours 小时';
  }

  bool _isValidInterval(String start, String end, Map<String, dynamic> rules) {
    return _validIntervalAt(
        start, end, rules, _earliestAllowedStart, _effectiveMinMinutes);
  }

  int get _earliestAllowedStart => _earliestAllowedStartFor(_day);

  int _earliestAllowedStartFor(String day) {
    final now = _schoolNow;
    final today = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    if (day.compareTo(today) < 0) return 24 * 60 + 1;
    if (day != today) return 0;
    return now.hour * 60 +
        now.minute +
        (now.second > 0 || now.millisecond > 0 ? 1 : 0);
  }

  bool _validIntervalAt(String start, String end, Map<String, dynamic> rules,
      int earliest, int minMinutes) {
    final startMinutes = _minutes(start);
    final duration = _minutes(end) - startMinutes;
    final max = rules['maxDuration'];
    return startMinutes >= earliest &&
        duration >= minMinutes &&
        (max is! num || duration <= max);
  }

  int _minimumStep(List<String> choices) {
    int? result;
    for (var i = 1; i < choices.length; i++) {
      final gap = _minutes(choices[i]) - _minutes(choices[i - 1]);
      if (gap > 0 && (result == null || gap < result)) result = gap;
    }
    return result ?? 1;
  }

  ({String start, String end}) _defaultTimeRange(List<String> choices,
      Map<String, dynamic> rules, String day, int minMinutes) {
    final earliest = _earliestAllowedStartFor(day);
    bool valid(String start, String end) =>
        _validIntervalAt(start, end, rules, earliest, minMinutes);
    final starts = choices
        .where((start) => choices.any((end) => valid(start, end)))
        .toList();
    if (starts.isEmpty) return (start: '', end: '');
    final start = starts.first;
    final ends = choices.where((end) => valid(start, end)).toList();
    if (ends.isEmpty) return (start: '', end: '');
    final end = ends.first;
    return (start: start, end: end);
  }

  List<String> _timeChoices(Map<String, dynamic> rules) {
    final firstMinute = ((rules['startHour'] as num?)?.toInt() ?? 0) * 60;
    final lastMinute = ((rules['endHour'] as num?)?.toInt() ?? 24) * 60;
    List<String> bounded(Iterable<String> values) => (values
        .where((value) =>
            _minutes(value) >= firstMinute &&
            _minutes(value) <= lastMinute &&
            _minutes(value) % 30 == 0)
        .toSet()
        .toList()
      ..sort());
    final direct = ThereBookingClient.strings(rules['meetingHalfHours']);
    if (direct.isNotEmpty) {
      final result = {...direct};
      final endHour = rules['endHour'];
      if (endHour is num) {
        result.add('${endHour.toInt().toString().padLeft(2, '0')}:00');
      }
      return bounded(result);
    }
    final blocks = ThereBookingClient.objects(rules['timeBlocks']);
    if (blocks.isNotEmpty) {
      final values = <String>{};
      for (final block in blocks) {
        if (block['disabled'] == true) continue;
        if (ThereBookingClient.string(block['start']) case final String value) {
          values.add(value);
        }
        if (ThereBookingClient.string(block['end']) case final String value) {
          values.add(value);
        }
      }
      return bounded(values);
    }
    final start = (rules['startHour'] as num?)?.toInt() ?? 0;
    final end = (rules['endHour'] as num?)?.toInt() ?? 24;
    final interval = (rules['meetingInterval'] as num?)?.toInt() ?? 30;
    if (interval <= 0) return [];
    return [
      for (var minute = start * 60; minute <= end * 60; minute += interval)
        if (minute % 30 == 0)
          '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}',
    ];
  }

  Widget _seatPage() {
    if (_loadingSeats) return _loadingBody();
    final colors = context.shuyoColors;
    final available = _rooms.where(_isBookable).length;
    final visible = _rooms.where((room) {
      final name = ThereBookingClient.string(room['name']) ?? '';
      return (!_onlyAvailable || _isBookable(room)) &&
          name.toLowerCase().contains(_seatFilter.toLowerCase());
    }).toList();
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        sliver: SliverToBoxAdapter(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(_selectedAreaPath,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600))),
              if (_venue == BookingVenue.studySpace)
                _infoLink('座位分布', _showSeatsMap, icon: Icons.map_outlined),
            ]),
            const SizedBox(height: 4),
            Text('${_monthDay(_day)}  $_start–$_end',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colors.textTertiary)),
            const SizedBox(height: 6),
            _seatStats(available, _rooms.length),
            const SizedBox(height: 14),
            TextField(
              decoration: const InputDecoration(
                  hintText: '搜索座位号', prefixIcon: Icon(Icons.search)),
              onChanged: (value) => setState(() => _seatFilter = value.trim()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('仅看可选座位'),
              value: _onlyAvailable,
              onChanged: (value) => setState(() => _onlyAvailable = value),
            ),
            if (_rooms.isEmpty) const Text('所选时段没有返回座位，请更换时间'),
            if (_rooms.isNotEmpty && visible.isEmpty) const Text('没有符合条件的座位'),
          ],
        )),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverLayoutBuilder(builder: (context, constraints) {
          final width = constraints.crossAxisExtent - 32;
          final columns = width >= 480 ? 6 : 5;
          return SliverGrid.builder(
            itemCount: visible.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 7,
              mainAxisSpacing: 7,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final room = visible[index];
              final id = ThereBookingClient.string(room['id']);
              final name =
                  ThereBookingClient.string(room['name']) ?? id ?? '——';
              final isPlaceholder =
                  ThereBookingClient.string(room['name']) == null && id == null;
              final enabled = _isBookable(room);
              final selected = id != null && id == _seatSelectionDraftId;
              return Tooltip(
                message: '$name${enabled ? '，可选' : '，不可选'}',
                child: InkWell(
                  onTap: !_viewOnly && enabled && !_busy && id != null
                      ? () => setState(
                          () => _seatSelectionDraftId = selected ? null : id)
                      : null,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.accent
                          : enabled
                              ? colors.surface
                              : colors.disabledFill,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: selected ? colors.accent : colors.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(name,
                            style: TextStyle(
                              color: isPlaceholder
                                  ? colors.textMuted
                                  : selected
                                      ? colors.onAccent
                                      : enabled
                                          ? colors.textPrimary
                                          : colors.textMuted,
                              fontWeight: FontWeight.w500,
                            )),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    ]);
  }

  Widget _seatBottomBar() {
    final room =
        _rooms.where((item) => item['id'] == _seatSelectionDraftId).firstOrNull;
    final colors = context.shuyoColors;
    final selectedRoomName = ThereBookingClient.string(room?['name']);
    return Container(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.08), blurRadius: 16)
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              Expanded(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    if (_viewOnly) ...[
                      Text('仅查看座位情况',
                          style: Theme.of(context).textTheme.bodySmall),
                      Text('${_monthDay(_day)} · $_start–$_end',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ] else ...[
                      Text('座位号',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colors.textTertiary,
                                  )),
                      Text(
                        selectedRoomName ?? '——',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontSize: 24,
                              color: selectedRoomName == null
                                  ? colors.textMuted
                                  : null,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_monthDay(_day)} · $_start–$_end',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ])),
              if (!_viewOnly)
                FilledButton(
                  onPressed:
                      _busy || _loadingSeats || _seatSelectionDraftId == null
                          ? null
                          : _confirmSeatSelection,
                  child: const Text('确认座位'),
                ),
            ]),
          ),
        ));
  }

  Widget _bookingsPage() {
    const filters = ['全部', '待履约', '进行中', '已结束', '已取消'];
    final history = _bookingHistory();
    final visible = history
        .where((item) =>
            _bookingFilter == '全部' ||
            LibraryBookingRecord.category(item, _schoolNow) == _bookingFilter)
        .toList();
    final visibleIndices = <String, int>{
      for (final (index, item) in visible.indexed)
        if (ThereBookingClient.string(item['id']) case final String id)
          '$_bookingAnimationEpoch:$id': index,
    };
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: _selectionTabBar(
          labels: filters,
          selectedIndex: filters.indexOf(_bookingFilter),
          onTap: (index) {
            if (_bookingFilter == filters[index]) return;
            setState(() {
              _bookingFilter = filters[index];
              _bookingAnimationEpoch++;
            });
          },
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          key: const ValueKey('booking-history-refresh'),
          onRefresh: () async {
            if (!_busy) await _loadBookings(force: true);
          },
          child: visible.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    if (!_bookingsLoading)
                      Text(history.isEmpty
                          ? (_bookingsIncomplete ? '暂无可显示的预约记录' : '暂无预约记录')
                          : '没有符合条件的预约'),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                  itemCount: visible.length,
                  findItemIndexCallback: (key) => key is ValueKey<String>
                      ? visibleIndices[key.value]
                      : null,
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    final id = ThereBookingClient.string(item['id']);
                    return _bookingTile(item, index,
                        key: ValueKey<String>('$_bookingAnimationEpoch:$id'));
                  },
                  separatorBuilder: (context, index) =>
                      CustomBackgroundScope.maybeOf(context) != null
                          ? const SizedBox.shrink()
                          : Divider(
                              height: 1, color: context.shuyoColors.border),
                ),
        ),
      ),
    ]);
  }

  void _retry() {
    switch (_step) {
      case _BookingStep.venue:
        break;
      case _BookingStep.area:
        unawaited(_loadVenue());
      case _BookingStep.viewVenues:
        break;
      case _BookingStep.allAreas:
        unawaited(_loadAllAreas());
      case _BookingStep.time:
        unawaited(_loadDays());
      case _BookingStep.seat:
        unawaited(_refreshSeats());
      case _BookingStep.bookings:
        unawaited(_loadBookings(force: true));
    }
  }

  void _openBookings() {
    if (_busy) return;
    setState(() {
      _slideForward = true;
      _step = _BookingStep.bookings;
      _bookingFilter = '全部';
    });
    unawaited(_reloadHistoryCache());
    unawaited(_refreshBookingsOnOpen());
  }

  Future<void> _refreshBookingsOnOpen() async {
    if (mounted && _step == _BookingStep.bookings) {
      await _loadBookings();
    }
  }

  Future<void> _loadVenue() async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _slideForward = true;
      _step = _BookingStep.area;
      _loading = true;
      _loadingLabel = '正在连接至${LibraryBookingNames.venue(_venue)}';
      _error = null;
      _selectedArea = null;
      _selectedRoomId = null;
      _rooms = [];
    });
    try {
      _profile = await _read<Map<String, dynamic>>(() async {
        await _selectBookingVenue(_venue);
        return _client.profile();
      }, validateAfterRecovery: _checkAccount);
      await _checkAccount(_profile!);
      final areas = await _read(() => _client.areas(_clockDay));
      if (!mounted || generation != _generation) return;
      setState(() {
        _areas = _areasForVenue(areas, _venue);
        _loading = false;
      });
      if (!_venue.isChaoxing) {
        try {
          await widget.accountService.setTherePendingRecovery(false);
        } on Object {
          // The business data is usable even if the local marker fails.
        }
      }
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      if (!_venue.isChaoxing) {
        try {
          await widget.accountService.setTherePendingRecovery(true);
        } on Object {
          // Keep the service error visible.
        }
      }
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = _friendlyError(error);
        });
      }
    }
  }

  Future<void> _loadAllAreas() async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _slideForward = true;
      _step = _BookingStep.allAreas;
      _viewOnly = true;
      _loading = true;
      _loadingAllAreas = true;
      _loadingLabel = '正在连接至座位预约系统';
      _allAreasError = null;
      _allAreasByVenue.clear();
      _error = null;
    });
    final failures = <String>[];
    final verifiedClients = <bool>{};
    for (final venue
        in BookingVenue.values.where(_viewVenueSelection.contains)) {
      if (!mounted || generation != _generation) return;
      setState(
          () => _loadingLabel = '正在连接至${LibraryBookingNames.venue(venue)}');
      try {
        await _read(() async {
          await _selectBookingVenue(venue);
          if (!verifiedClients.contains(venue.isChaoxing)) {
            await _checkAccount(await _client.profile());
            verifiedClients.add(venue.isChaoxing);
          }
          return true;
        });
        final areas = await _read(() => _client.areas(_clockDay));
        if (!mounted || generation != _generation) return;
        setState(() {
          _allAreasByVenue[venue] = _areasForVenue(areas, venue);
          _loading = false;
        });
      } on Object catch (error) {
        failures.add(
            '${LibraryBookingNames.venue(venue)}：${_friendlyError(error)}');
      }
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _loadingAllAreas = false;
      if (_allAreasByVenue.isEmpty) {
        _error = failures.firstOrNull ?? '暂时无法加载分区';
      } else if (failures.isNotEmpty) {
        _allAreasError = '部分场馆暂时无法加载';
      }
    });
  }

  Future<void> _loadDays() async {
    final generation = ++_generation;
    final venue = _venue;
    final client = _clientForVenue(venue);
    final id = ThereBookingClient.string(_selectedArea?['id']);
    if (id == null) return;
    setState(() {
      _loading = true;
      _loadingLabel = '正在加载可预约日期';
      _error = null;
      _loadingAreaRules = false;
      _areaRulesError = null;
      _areaData = null;
      _prefetchedDays.clear();
      _dayRuleErrors.clear();
      _clearPreview();
    });
    try {
      final overview = await _read(() async {
        await _selectBookingVenue(venue);
        await _checkAccount(await client.profile(), client: client);
        return client.overview(_clockDay);
      }, venue: venue, client: client);
      if (!mounted || generation != _generation) return;
      final days = _bookingDays(overview);
      setState(() => _loadingLabel = '正在准备可预约时段和座位数');
      Future<({String day, _PrefetchedBookingDay? data, String? error})>
          loadDay(String day) async {
        try {
          final data = await _prefetchBookingDay(day, id, venue, client);
          return (day: day, data: data, error: null);
        } on Object catch (error) {
          return (day: day, data: null, error: _friendlyError(error));
        }
      }

      final results = await Future.wait(days.map(loadDay));
      if (!mounted || generation != _generation) return;
      setState(() {
        _days = days;
        for (final result in results) {
          if (result.data case final _PrefetchedBookingDay data) {
            _prefetchedDays[result.day] = data;
          } else if (result.error case final String error) {
            _dayRuleErrors[result.day] = error;
          }
        }
        if (days.isNotEmpty) {
          _showPrefetchedDay(days.contains(_day) ? _day : days.first);
        }
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _friendlyError(error);
      });
    }
  }

  Future<_PrefetchedBookingDay> _prefetchBookingDay(String day, String id,
      BookingVenue venue, ThereBookingClient client) async {
    final data = await _read(() => client.area(id, day, day),
        venue: venue, client: client);
    final rules = ThereBookingClient.object(data['bookingTimes']) ?? const {};
    final choices = _timeChoices(rules);
    final explicitMin = rules['minDuration'];
    final minMinutes = explicitMin is num && explicitMin > 0
        ? explicitMin.toInt()
        : _minimumStep(choices);
    final defaults = _defaultTimeRange(choices, rules, day, minMinutes);
    int? available;
    List<Map<String, dynamic>> rooms = [];
    String? previewError;
    if (_validIntervalAt(defaults.start, defaults.end, rules,
        _earliestAllowedStartFor(day), minMinutes)) {
      try {
        final preview = await _read(
            () => client.area(
                id, '$day ${defaults.start}', '$day ${defaults.end}'),
            venue: venue,
            client: client);
        rooms = ThereBookingClient.objects(preview['rooms']);
        available = rooms.where(_isBookable).length;
      } on Object catch (error) {
        previewError = _friendlyError(error);
      }
    }
    return _PrefetchedBookingDay(
      areaData: data,
      minMinutes: minMinutes,
      start: defaults.start,
      end: defaults.end,
      available: available,
      rooms: rooms,
      previewError: previewError,
    );
  }

  Future<void> _loadAreaRules() async {
    final id = ThereBookingClient.string(_selectedArea?['id']);
    if (id == null) return;
    final generation = ++_generation;
    final day = _day;
    final venue = _venue;
    final client = _clientForVenue(venue);
    setState(() {
      _loadingAreaRules = true;
      _areaRulesError = null;
      if (_areaData == null) {
        _start = '';
        _end = '';
      }
      _clearPreview();
    });
    try {
      final data = await _prefetchBookingDay(day, id, venue, client);
      if (!mounted || generation != _generation) return;
      setState(() {
        _prefetchedDays[day] = data;
        _dayRuleErrors.remove(day);
        _showPrefetchedDay(day);
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingAreaRules = false;
        _areaRulesError = _friendlyError(error);
        _dayRuleErrors[day] = _areaRulesError!;
      });
    }
  }

  Future<void> _refreshSeats() async {
    final id = ThereBookingClient.string(_selectedArea?['id']);
    if (id == null || !mounted || _step != _BookingStep.seat) return;
    final generation = ++_generation;
    final day = _day;
    final start = _start;
    final end = _end;
    final venue = _venue;
    final client = _clientForVenue(venue);
    setState(() {
      _loadingSeats = true;
      _loadingLabel = '正在加载分区座位情况';
      _seatSelectionDraftId = _selectedRoomId;
    });
    try {
      final result = await _read(() async {
        await _selectBookingVenue(venue);
        return client.area(id, '$day $start', '$day $end');
      }, venue: venue, client: client);
      if (!mounted || generation != _generation) return;
      setState(() {
        _areaData = result;
        _rooms = ThereBookingClient.objects(result['rooms']);
        _previewRooms = _rooms;
        _previewAvailable = _rooms.where(_isBookable).length;
        _previewKey = _currentPreviewKey;
        if (!_rooms.any((room) =>
            room['id'] == _seatSelectionDraftId && _isBookable(room))) {
          _seatSelectionDraftId = null;
        }
        if (!_rooms.any(
            (room) => room['id'] == _selectedRoomId && _isBookable(room))) {
          _selectedRoomId = null;
        }
        _loadingSeats = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingSeats = false;
        _error = _friendlyError(error);
      });
    }
  }

  Future<void> _loadBookings({
    bool showFailures = true,
    bool force = false,
  }) async {
    if (!mounted) return;
    final requested = BookingVenue.values
        .where((venue) =>
            force ||
            _bookingLoads.containsKey(venue) ||
            !_isFresh(_bookingsUpdatedAt[venue]))
        .toList();
    final startedNew =
        requested.any((venue) => !_bookingLoads.containsKey(venue));
    final results = await Future.wait(requested.map(
        (venue) => _loadVenueBookings(venue, interactiveAuth: showFailures)));
    if (!mounted || !showFailures || !startedNew || !results.contains(false)) {
      return;
    }
    final successful = BookingVenue.values
        .where((venue) => _isFresh(_bookingsUpdatedAt[venue]))
        .length;
    _showMessage(successful == 0 && _bookingHistory().isEmpty
        ? '预约加载失败，请下拉重试'
        : successful == 0
            ? '未能更新预约状态，已显示本地保存的预约记录'
            : '部分预约加载失败，请下拉重试');
  }

  Future<bool> _loadVenueBookings(BookingVenue venue,
      {required bool interactiveAuth}) {
    final pending = _bookingLoads[venue];
    if (pending != null) return pending;
    late final Future<bool> load;
    load = _fetchVenueBookings(venue,
            interactiveAuth: interactiveAuth,
            prefetchDetails: _step == _BookingStep.bookings)
        .whenComplete(() {
      if (!identical(_bookingLoads[venue], load)) return;
      _bookingLoads.remove(venue);
      if (mounted) setState(() {});
    });
    _bookingLoads[venue] = load;
    if (mounted) setState(() {});
    return load;
  }

  Future<bool> _fetchVenueBookings(BookingVenue venue,
      {required bool interactiveAuth, required bool prefetchDetails}) async {
    final client = _clientForVenue(venue);
    _bookingsUpdatedAt.remove(venue);
    try {
      await _read(() async {
        await _ensureVenueSelected(venue, client);
        await _checkAccount(await client.profile(), client: client);
      }, venue: venue, client: client, interactiveAuth: interactiveAuth);
      final recent = await _read(client.recent,
          venue: venue, client: client, interactiveAuth: interactiveAuth);
      if (!mounted) return false;
      final confirmed = <Map<String, dynamic>>[];
      var writeStatusPending = false;
      for (final item in recent) {
        final id = ThereBookingClient.string(item['id']);
        if (id == null || item['roomType'] != venue.roomType) continue;
        final expectsFinish = _awaitingWriteStatus[id];
        if (expectsFinish != null) {
          if (!_writeStatusConfirmed(item, expectsFinish)) {
            writeStatusPending = true;
            continue;
          }
          _awaitingWriteStatus.remove(id);
        }
        confirmed.add(item);
      }
      final oldIds = _recent
          .where((item) => item['roomType'] == venue.roomType)
          .map((item) => ThereBookingClient.string(item['id']))
          .toSet();
      setState(() {
        _prefetchedDetails.removeWhere((id, _) => oldIds.contains(id));
        _recent.removeWhere((item) => item['roomType'] == venue.roomType);
        _recent.addAll(confirmed);
        _recent.sort((a, b) => (ThereBookingClient.string(b['beginTime']) ?? '')
            .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
        _bookingLoadFailures.remove(venue);
      });
      _cacheRecentForVenue(venue, confirmed);
      if (prefetchDetails) {
        for (final item in confirmed) {
          final id = ThereBookingClient.string(item['id'])!;
          final category = LibraryBookingRecord.category(item, _schoolNow);
          if (venue.isChaoxing ||
              category == '已取消' ||
              LibraryBookingRecord.finishedEarly(item) ||
              category == '已结束' && item['endTime'] != null) {
            continue;
          }
          Map<String, dynamic>? detail;
          try {
            detail = await _read(() => client.detail(id),
                venue: venue, client: client, interactiveAuth: interactiveAuth);
          } on Object {
            if (ThereBookingClient.strings(item['abilities'])
                .contains('cancel')) {
              detail = item;
            }
          }
          if (!mounted) return false;
          if (detail != null) {
            final resolved = detail;
            setState(() {
              _prefetchedDetails[id] = resolved;
              final index = _recent.indexWhere((record) => record['id'] == id);
              if (index >= 0 && resolved['abilities'] != null) {
                _recent[index] = {
                  ..._recent[index],
                  'abilities': resolved['abilities']
                };
              }
            });
          }
        }
      }
      if (!mounted) return false;
      if (!writeStatusPending) _bookingsUpdatedAt[venue] = _schoolNow;
      return true;
    } on Object {
      if (mounted) setState(() => _bookingLoadFailures.add(venue));
      return false;
    }
  }

  Future<bool> _authenticate({
    BookingVenue? venue,
    ThereBookingClient? client,
    bool interactive = true,
    int? expectedRevision,
  }) async {
    final revision = expectedRevision ?? _authenticationRevision;
    final preceding = _authenticationQueue;
    final finished = Completer<void>();
    _authenticationQueue = finished.future;
    await preceding;
    try {
      if (!mounted || revision != _authenticationRevision) return false;
      final restored = await _authenticateNow(
        venue: venue,
        client: client,
        interactive: interactive,
      );
      // Queued failures from the same action must not reopen a cancelled login.
      if (!restored && interactive) _authenticationRevision++;
      return restored;
    } finally {
      finished.complete();
    }
  }

  Future<bool> _authenticateNow({
    BookingVenue? venue,
    ThereBookingClient? client,
    bool interactive = true,
  }) async {
    final activeVenue = venue ?? _activeClientVenue;
    final activeClient = client ?? _client;
    if (activeVenue.isChaoxing) {
      try {
        activeClient.resetSession();
        await activeClient.selectVenue(activeVenue);
        await _checkAccount(await activeClient.profile(), client: activeClient);
        return true;
      } on ThereBookingException catch (error) {
        if (error.kind != ThereFailureKind.loginRequired) rethrow;
        if (!await _requestCampusLogin(
          ssoExpired: error.ssoExpired,
          interactive: interactive,
          chaoxing: true,
        )) {
          return false;
        }
      }
      return _authenticateNow(
          venue: activeVenue, client: activeClient, interactive: false);
    }
    try {
      await activeClient.prepareOAuth();
    } on ThereBookingException catch (error) {
      if (error.kind != ThereFailureKind.webVpnLoginRequired ||
          !await _restoreWebVpn(interactive)) {
        rethrow;
      }
      activeClient.resetSession();
      await activeClient.prepareOAuth();
    }
    final callback = await widget.accountService.authorizeThere();
    if (callback != null) {
      await activeClient.completeOAuth(callback);
      return true;
    }
    if (!await _requestCampusLogin(
        ssoExpired: true, interactive: interactive)) {
      return false;
    }
    activeClient.resetSession();
    return _authenticateNow(
        venue: activeVenue, client: activeClient, interactive: false);
  }

  Future<bool> _requestCampusLogin({
    required bool ssoExpired,
    required bool interactive,
    bool chaoxing = false,
  }) async {
    if (!mounted) return false;
    interactive = interactive && ModalRoute.of(context)?.isCurrent != false;
    if (ssoExpired && widget.onCampusSessionExpired != null) {
      return widget.onCampusSessionExpired!(interactive);
    }
    if (!interactive) return false;
    final login = chaoxing
        ? widget.onChaoxingLoginRequired ?? widget.onCampusLoginRequired
        : widget.onCampusLoginRequired;
    if (login != null) return login();
    final result = await Navigator.of(context).push<NativeLoginResult>(
      MaterialPageRoute(
        builder: (_) => ShuYoRouteSurface(
          child: chaoxing
              ? const NativeLoginPage()
              : const NativeLoginPage.there(),
        ),
      ),
    );
    return result == NativeLoginResult.authenticated;
  }

  Future<bool> _restoreWebVpn(bool interactive) async {
    interactive =
        interactive && mounted && ModalRoute.of(context)?.isCurrent != false;
    final recover = widget.onWebVpnRecoveryRequired;
    final restored = recover != null
        ? await recover(interactive)
        : interactive
            ? await widget.onWebVpnSessionRequired?.call() ?? false
            : false;
    if (!restored && interactive) _authenticationRevision++;
    return restored;
  }

  Future<T> _reportExpiredSession<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on ThereBookingException catch (error) {
      if (error.ssoExpired) {
        await widget.onCampusSessionExpired?.call(false);
      }
      rethrow;
    }
  }

  Future<T> _read<T>(
    Future<T> Function() operation, {
    Future<void> Function(T)? validateAfterRecovery,
    BookingVenue? venue,
    ThereBookingClient? client,
    bool interactiveAuth = true,
  }) async {
    final activeVenue = venue ?? _activeClientVenue;
    final activeClient = client ?? _client;
    final revision = _authenticationRevision;
    try {
      return await operation();
    } on ThereBookingException catch (error) {
      if (revision != _authenticationRevision) rethrow;
      if (error.kind == ThereFailureKind.webVpnLoginRequired &&
          widget.useWebVpn) {
        final restored = await _restoreWebVpn(interactiveAuth);
        if (!restored) rethrow;
        activeClient.resetSession();
        return _reportExpiredSession(() => _readAfterRecovery(
            operation, validateAfterRecovery,
            venue: activeVenue,
            client: activeClient,
            selectGlobalVenue: client == null));
      }
      if (error.kind != ThereFailureKind.loginRequired) rethrow;
    }
    final authenticated = await _authenticate(
      venue: activeVenue,
      client: activeClient,
      interactive: interactiveAuth,
      expectedRevision: revision,
    );
    if (!authenticated) {
      throw const ThereBookingException(
        ThereFailureKind.loginRequired,
        '请先登录图书馆预约',
      );
    }
    return _reportExpiredSession(() => _readAfterRecovery(
        operation, validateAfterRecovery,
        venue: activeVenue,
        client: activeClient,
        selectGlobalVenue: client == null));
  }

  Future<T> _readAfterRecovery<T>(
    Future<T> Function() operation,
    Future<void> Function(T)? validateAfterRecovery, {
    required BookingVenue venue,
    required ThereBookingClient client,
    required bool selectGlobalVenue,
  }) async {
    if (selectGlobalVenue) {
      await _selectBookingVenue(venue);
    } else {
      await client.selectVenue(venue);
    }
    if (validateAfterRecovery != null) {
      final result = await operation();
      await validateAfterRecovery(result);
      return result;
    }
    await _checkAccount(await client.profile(), client: client);
    return operation();
  }

  Future<void> _checkAccount(Map<String, dynamic> profile,
      {ThereBookingClient? client}) async {
    final expected = await AcademicAccountStore().loadStudentId();
    if (expected != null &&
        !ThereBookingClient.matchesAccount(profile, expected)) {
      await (client ?? _client).clearSession();
      throw const ThereBookingException(
        ThereFailureKind.business,
        '图书馆预约登录的是另一个校园账户，请退出校园账户后重新登录',
      );
    }
  }

  Future<void> _createBooking() async {
    final areaId = ThereBookingClient.string(_selectedArea?['id']);
    final roomId = _selectedRoomId;
    if (!_canSelectSeat ||
        _selectedPreviewRoom == null ||
        areaId == null ||
        roomId == null) {
      return;
    }
    final room =
        _previewRooms.where((item) => item['id'] == roomId).firstOrNull;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认预约'),
            content: Text('$_selectedAreaPath\n'
                '${ThereBookingClient.string(room?['name']) ?? '座位'}\n'
                '$_day  $_start—$_end'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('提交'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final venue = _venue;
    final client = _clientForVenue(venue);
    setState(() {
      _busy = true;
      _slideForward = false;
      _step = _BookingStep.venue;
      _clearPreview();
    });
    String? createdId;
    try {
      await _bookingLoads[venue];
      if (!mounted) return;
      _bookingsUpdatedAt.remove(venue);
      _homeAreasUpdatedAt.remove(venue);
      await _selectBookingVenue(venue, refresh: true);
      createdId = await client.create(
        areaId: areaId,
        roomId: roomId,
        day: _day,
        start: _start,
        end: _end,
      );
    } on ThereBookingException catch (error) {
      if (error.kind == ThereFailureKind.uncertain) {
        try {
          final recent =
              await _read(client.recent, venue: venue, client: client);
          if (mounted) {
            _cacheRecentForVenue(venue, recent);
            setState(() {
              _recent.removeWhere((item) => item['roomType'] == venue.roomType);
              _recent.addAll(recent);
            });
          }
        } on Object {
          // Keep the uncertain result; a new create request is not automatic.
        }
      }
      if (error.kind == ThereFailureKind.loginRequired ||
          error.kind == ThereFailureKind.webVpnLoginRequired) {
        await _recoverAfterWrite(
          webVpn: error.kind == ThereFailureKind.webVpnLoginRequired,
        );
      } else if (mounted) {
        _showMessage(error.message);
      }
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
    if (createdId == null || !mounted) {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
      return;
    }
    Map<String, dynamic>? createdBooking;
    try {
      for (var attempt = 0; attempt < 3 && mounted; attempt++) {
        final recent = await _read(client.recent, venue: venue, client: client);
        if (!mounted) return;
        createdBooking = recent
            .where((item) => ThereBookingClient.string(item['id']) == createdId)
            .firstOrNull;
        setState(() {
          _recent.removeWhere((item) => item['roomType'] == venue.roomType);
          _recent.addAll(recent);
          _recent.sort((a, b) =>
              (ThereBookingClient.string(b['beginTime']) ?? '')
                  .compareTo(ThereBookingClient.string(a['beginTime']) ?? ''));
        });
        _cacheRecentForVenue(venue, recent);
        if (createdBooking != null) break;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      if (createdBooking == null && mounted) {
        _showMessage('预约已创建，列表尚未同步，请稍后查看我的预约');
      }
    } on Object {
      if (mounted) _showMessage('预约已创建，但最新记录暂时无法加载，请稍后刷新');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
    if (createdBooking != null && mounted) {
      _bookingsUpdatedAt[venue] = _schoolNow;
      unawaited(_loadHomeVenueAreas(venue, force: true));
    }
    if (createdBooking != null && mounted) await _openDetail(createdBooking);
  }

  Future<void> _openDetail(Map<String, dynamic> booking) async {
    final id = ThereBookingClient.string(booking['id']);
    if (id == null || !_openingDetails.add(id)) return;
    try {
      final venue = BookingVenue.values
              .where((item) => item.roomType == booking['roomType'])
              .firstOrNull ??
          _venue;
      final prefetched = _prefetchedDetails[id];
      final category = LibraryBookingRecord.category(booking, _schoolNow);
      // Refresh details for current cancel and finish abilities.
      final needsDetail = venue.isChaoxing ||
          category == '待履约' ||
          category == '进行中' ||
          prefetched == null &&
              ThereBookingClient.string(booking['beginTime']) == null;
      final client = _clientForVenue(venue);
      Map<String, dynamic>? fetched;
      if (needsDetail) {
        try {
          fetched = await _read<Map<String, dynamic>>(() async {
            await _selectBookingVenue(venue);
            return client.detail(id);
          }, venue: venue, client: client);
        } on Object {
          // Recent can still provide the booking time and available actions.
          if (venue.isChaoxing ||
              (prefetched == null &&
                  booking['abilities'] == null &&
                  booking['beginTime'] == null)) {
            rethrow;
          }
        }
      }
      if (fetched != null) _prefetchedDetails[id] = fetched;
      final Map<String, dynamic> detail = {
        ...booking,
        ...?prefetched,
        ...?fetched,
      };
      final abilities = ThereBookingClient.strings(detail['abilities']);
      final canCancel = abilities.contains('cancel');
      final canSign = venue.isChaoxing && abilities.contains('sign');
      final areaName = LibraryBookingNames.area(
        venue,
        ThereBookingClient.string(detail['officeAreaName']) ??
            ThereBookingClient.string(booking['officeAreaName']) ??
            ThereBookingClient.string(detail['allOfficeAreaName']) ??
            ThereBookingClient.string(booking['allOfficeAreaName']) ??
            '',
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: context.shuyoColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        clipBehavior: Clip.antiAlias,
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                        child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                          color: sheetContext.shuyoColors.borderStrong,
                          borderRadius: BorderRadius.circular(4)),
                    )),
                    const SizedBox(height: 20),
                    Text(
                        ThereBookingClient.string(detail['roomName']) ?? '预约详情',
                        style: Theme.of(sheetContext).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Row(children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: sheetContext.shuyoColors.accent,
                              shape: BoxShape.circle)),
                      const SizedBox(width: 7),
                      Text(LibraryBookingRecord.category(detail, _schoolNow),
                          style: Theme.of(sheetContext)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: sheetContext.shuyoColors.accent)),
                    ]),
                    const SizedBox(height: 18),
                    Divider(color: sheetContext.shuyoColors.border),
                    const SizedBox(height: 12),
                    _bookingDetailField(
                        sheetContext, '场馆', _BookingCampus.venueLabel(venue)),
                    _bookingDetailField(sheetContext, '分区', areaName),
                    _bookingDetailField(
                        sheetContext,
                        '开始时间',
                        LibraryBookingRecord.displayTime(
                            detail['beginTime'], _schoolNow)),
                    _bookingDetailField(
                        sheetContext,
                        '结束时间',
                        LibraryBookingRecord.displayTime(
                            detail['endTime'], _schoolNow)),
                    if (ThereBookingClient.string(detail['createdAt'])
                        case final String createdAt)
                      _bookingDetailField(
                          sheetContext,
                          '预约时间',
                          createdAt.length >= 16
                              ? createdAt.substring(0, 16)
                              : createdAt),
                    if (canCancel || canSign) ...[
                      const SizedBox(height: 6),
                      Row(children: [
                        if (canCancel)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                unawaited(_cancelBooking(id, venue: venue));
                              },
                              icon: const Icon(Icons.event_busy_outlined),
                              label: const Text('取消预约'),
                            ),
                          ),
                        if (canCancel && canSign) const SizedBox(width: 12),
                        if (canSign)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                unawaited(_signBooking(id, venue: venue));
                              },
                              icon: const Icon(Icons.how_to_reg_outlined),
                              label: const Text('签到'),
                            ),
                          ),
                      ]),
                    ],
                    if (ThereBookingClient.strings(detail['abilities'])
                        .contains('close')) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              unawaited(_finishBooking(id, venue: venue));
                            },
                            icon: const Icon(Icons.chair_alt_outlined),
                            label: const Text('退座'),
                          )),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      _openingDetails.remove(id);
    }
  }

  Widget _bookingDetailField(BuildContext context, String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
            width: 96,
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.shuyoColors.textSecondary))),
        Expanded(child: Text(value)),
      ]),
    );
  }

  Future<void> _refreshAfterBookingWrite(BookingVenue venue) async {
    // A write needs a read started after it, even if an earlier read is pending.
    await _bookingLoads[venue];
    if (!mounted) return;
    _homeAreasUpdatedAt.remove(venue);
    final success = await _loadVenueBookings(venue, interactiveAuth: true);
    if (!success) {
      throw const ThereBookingException(
          ThereFailureKind.unreachable, '预约状态暂时无法更新');
    }
    if (!mounted) return;
    if (_campus.venues.contains(venue) &&
        _homeAreasByVenue.containsKey(venue)) {
      await _homeAreaLoads[venue];
      if (!mounted) return;
      await _loadHomeVenueAreas(venue, force: true);
    }
    if (_step == _BookingStep.seat && _venue == venue) await _refreshSeats();
  }

  Future<void> _cancelBooking(String id, {required BookingVenue venue}) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('取消这条预约'),
            content: const Text('取消后需重新预约'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _bookingLoads[venue];
    if (!mounted) return;
    setState(() => _busy = true);
    var cancelled = false;
    var uncertain = false;
    final client = _clientForVenue(venue);
    try {
      await _read(() => _selectBookingVenue(venue, refresh: true),
          venue: venue, client: client);
      await client.cancel(id);
      cancelled = true;
    } on ThereBookingException catch (error) {
      if (error.kind == ThereFailureKind.loginRequired ||
          error.kind == ThereFailureKind.webVpnLoginRequired) {
        await _recoverAfterWrite(
          webVpn: error.kind == ThereFailureKind.webVpnLoginRequired,
        );
      } else if (mounted) {
        uncertain = error.kind == ThereFailureKind.uncertain;
        _showMessage(error.message);
      }
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if ((!cancelled && !uncertain) || !mounted) return;
    if (cancelled) {
      _showMessage('已取消预约');
      _awaitingWriteStatus[id] = false;
      _removeBookingFromRecent(id);
    }
    try {
      await _refreshAfterBookingWrite(venue);
    } on Object {
      if (mounted) {
        _showMessage(cancelled ? '已取消预约，列表暂时无法刷新' : '取消结果暂未确认，请稍后刷新我的预约');
      }
    }
  }

  Future<void> _finishBooking(String id, {required BookingVenue venue}) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认退座'),
            content: const Text('退座后本次预约将立即结束，座位会释放，且无法恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _bookingLoads[venue];
    if (!mounted) return;
    setState(() => _busy = true);
    var finished = false;
    final client = _clientForVenue(venue);
    try {
      await _read(() => _selectBookingVenue(venue, refresh: true),
          venue: venue, client: client);
      await client.finish(id);
      finished = true;
    } on ThereBookingException catch (error) {
      if (error.kind == ThereFailureKind.loginRequired ||
          error.kind == ThereFailureKind.webVpnLoginRequired) {
        await _recoverAfterWrite(
          webVpn: error.kind == ThereFailureKind.webVpnLoginRequired,
        );
      } else if (mounted) {
        _showMessage(error.message);
      }
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!finished || !mounted) return;
    _showMessage('已提交退座，正在读取最终状态');
    _awaitingWriteStatus[id] = true;
    _removeBookingFromRecent(id);
    try {
      await _refreshAfterBookingWrite(venue);
    } on Object {
      if (mounted) _showMessage('操作已提交，列表暂时无法刷新');
    }
  }

  Future<void> _signBooking(String id, {required BookingVenue venue}) async {
    if (!venue.isChaoxing) return;
    await _bookingLoads[venue];
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    var signed = false;
    var uncertain = false;
    final client = _clientForVenue(venue) as ChaoxingBookingAdapter;
    try {
      await _read(() => _selectBookingVenue(venue, refresh: true),
          venue: venue, client: client);
      await client.sign(id);
      signed = true;
    } on ThereBookingException catch (error) {
      if (error.kind == ThereFailureKind.loginRequired ||
          error.kind == ThereFailureKind.webVpnLoginRequired) {
        await _recoverAfterWrite(
          webVpn: error.kind == ThereFailureKind.webVpnLoginRequired,
        );
      } else if (mounted) {
        uncertain = error.kind == ThereFailureKind.uncertain;
        _showMessage(error.message);
      }
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if ((!signed && !uncertain) || !mounted) return;
    if (signed) _showMessage('签到已提交，正在读取最新状态');
    try {
      await _refreshAfterBookingWrite(venue);
    } on Object {
      if (mounted) {
        _showMessage(signed ? '签到已提交，列表暂时无法刷新' : '签到结果暂未确认，请稍后刷新我的预约');
      }
    }
  }

  Future<void> _recoverAfterWrite({bool webVpn = false}) async {
    try {
      final recovered =
          webVpn ? await _restoreWebVpn(true) : await _authenticate();
      if (!recovered || !mounted) return;
      if (webVpn) _client.resetSession();
      if (_step == _BookingStep.bookings) {
        await _loadBookings(force: true);
      } else {
        await _loadVenue();
      }
      if (mounted) _showMessage('登录已恢复，请重新确认操作');
    } on Object catch (error) {
      if (mounted) _showMessage(_friendlyError(error));
    }
  }

  List<String> _bookingDays(Map<String, dynamic> overview) {
    final raw = overview['bookingDays'];
    if (raw is! List) return [];
    final days = <String>{};
    for (final item in raw) {
      final value = item is Map ? item['day'] : item;
      final day = ThereBookingClient.string(value);
      if (day != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
        days.add(day);
      }
    }
    final today = _clockDay;
    final date = DateTime.parse(today);
    final next = DateTime.utc(date.year, date.month, date.day + 1);
    final tomorrow = '${next.year.toString().padLeft(4, '0')}-'
        '${next.month.toString().padLeft(2, '0')}-'
        '${next.day.toString().padLeft(2, '0')}';
    return [
      if (days.contains(today)) today,
      if (days.contains(tomorrow)) tomorrow
    ];
  }

  bool _isBookable(Map<String, dynamic> room) =>
      room['disabled'] != true &&
      room['isBusy'] != true &&
      room['isBooked'] != true &&
      ThereBookingClient.strings(room['abilities']).contains('booking');

  String _friendlyError(Object error) {
    if (error is ThereBookingException) return error.message;
    return '图书馆预约暂时无法使用，请稍后重试';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.fixed, content: Text(message)),
    );
  }
}
