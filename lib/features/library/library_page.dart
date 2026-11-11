import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/library_book_item.dart';
import '../../data/models/library_daily_recommend.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/widgets/empty_state.dart';
import 'library_daily_recommend_card.dart';
import 'library_daily_recommend_skeleton.dart';
import 'library_rank_gallery.dart';
import 'library_rank_list_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.authService,
    this.apiClient,
    this.onCampusSessionExpired,
  });

  final LibraryAuthService? authService;
  final LibraryApiClient? apiClient;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final LibraryAuthService _authService =
      widget.authService ?? LibraryAuthService();
  late final LibraryApiClient _apiClient =
      widget.apiClient ?? LibraryApiClient();
  bool _isInitialAuthorizing = false;
  LibraryAuthSession? _session;
  LibraryDailyRecommend? _dailyRecommend;
  LibraryRankType _selectedRankType = LibraryRankType.hotLoan;
  final Map<LibraryRankType, List<LibraryBookItem>> _rankLists = {};
  final Map<LibraryRankType, bool> _rankLoading = {};
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_performAuthorization(isInitial: true));
  }

  Future<void> _loadDailyRecommend([LibraryAuthSession? session]) async {
    final currentSession = session ?? _session;
    try {
      final book =
          await _apiClient.fetchDailyRecommend(session: currentSession);
      if (!mounted) return;
      setState(() => _dailyRecommend = book);
    } on Object {
      // 今日推荐加载失败不阻断借阅主流程
    }
  }

  Future<void> _loadRankList(
    LibraryRankType type, {
    LibraryAuthSession? session,
    bool force = false,
  }) async {
    if (!force && _rankLists.containsKey(type)) return;
    if (_rankLoading[type] == true) return;

    final currentSession = session ?? _session;
    setState(() => _rankLoading[type] = true);

    try {
      final books = await _apiClient.fetchRankList(
        type: type,
        page: 1,
        rows: 10,
        session: currentSession,
      );
      if (!mounted) return;
      setState(() {
        _rankLists[type] = books;
      });
    } on Object {
      // 榜单加载失败不阻断主流程
    } finally {
      if (mounted) {
        setState(() => _rankLoading[type] = false);
      }
    }
  }

  void _openRankListPage(LibraryRankType initialType) {
    Navigator.of(context).push(
      shuyoRoute(
        builder: (context) => LibraryRankListPage(
          apiClient: _apiClient,
          session: _session,
          initialType: initialType,
        ),
      ),
    );
  }

  Future<void> _performAuthorization({
    bool force = false,
    bool isInitial = false,
  }) async {
    if (_isInitialAuthorizing) return;
    setState(() {
      if (isInitial) {
        _isInitialAuthorizing = true;
      }
      _error = null;
    });

    try {
      final session = await _authService.authorize(force: force);
      if (!mounted) return;
      setState(() {
        _session = session;
        _error = null;
      });
      unawaited(_loadDailyRecommend(session));
      unawaited(
          _loadRankList(_selectedRankType, session: session, force: force));
    } on LibraryCampusAuthRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      if (e.ssoExpired) {
        final recovered =
            await widget.onCampusSessionExpired?.call(true) ?? false;
        if (recovered && mounted) {
          unawaited(_performAuthorization(force: true, isInitial: isInitial));
        }
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted && isInitial) {
        setState(() => _isInitialAuthorizing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图书馆借阅'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _isInitialAuthorizing
                ? const LinearProgressIndicator(
                    key: ValueKey('library-auth-progress'),
                    minHeight: 2,
                  )
                : null,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _performAuthorization(force: true, isInitial: false);
        },
        child: _error != null
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 24),
                children: [
                  _buildBody(),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (_dailyRecommend != null)
                    LibraryDailyRecommendCard(book: _dailyRecommend!)
                  else
                    const LibraryDailyRecommendSkeleton(),
                  const SizedBox(height: 14),
                  LibraryRankGallery(
                    selectedType: _selectedRankType,
                    books: _rankLists[_selectedRankType] ?? const [],
                    isLoading: _rankLoading[_selectedRankType] == true,
                    onTypeChanged: (type) {
                      setState(() => _selectedRankType = type);
                      unawaited(_loadRankList(type));
                    },
                    onViewAll: () => _openRankListPage(_selectedRankType),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      final message =
          error is LibraryAuthException ? error.message : '获取图书馆授权失败，请稍后重试';
      return EmptyState(
        icon: Icons.error_outline,
        title: '未能获取借阅授权',
        message: message,
        action: FilledButton(
          onPressed: () => unawaited(_performAuthorization(force: true)),
          child: const Text('重新授权'),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
