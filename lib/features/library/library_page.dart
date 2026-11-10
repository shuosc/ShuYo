import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/services/library_auth_service.dart';
import '../../shared/widgets/empty_state.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    this.authService,
    this.onCampusSessionExpired,
  });

  final LibraryAuthService? authService;
  final Future<bool> Function(bool interactive)? onCampusSessionExpired;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final LibraryAuthService _authService =
      widget.authService ?? LibraryAuthService();
  bool _isAuthorizing = false;
  LibraryAuthSession? _session;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_performAuthorization());
  }

  Future<void> _performAuthorization({bool force = false}) async {
    if (_isAuthorizing) return;
    setState(() {
      _isAuthorizing = true;
      _error = null;
    });

    try {
      final session = await _authService.authorize(force: force);
      if (!mounted) return;
      setState(() {
        _session = session;
        _error = null;
      });
    } on LibraryCampusAuthRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      if (e.ssoExpired) {
        final recovered =
            await widget.onCampusSessionExpired?.call(true) ?? false;
        if (recovered && mounted) {
          unawaited(_performAuthorization(force: true));
        }
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) {
        setState(() => _isAuthorizing = false);
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
            child: _isAuthorizing
                ? const LinearProgressIndicator(
                    key: ValueKey('library-auth-progress'),
                    minHeight: 2,
                  )
                : null,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _performAuthorization(force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.75,
              child: _buildBody(),
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

    if (_isAuthorizing && _session == null) {
      return const SizedBox.shrink();
    }

    final user = _session?.userName;
    final hint = user != null && user.isNotEmpty
        ? '欢迎你，$user。当前借阅列表为空。'
        : '当前借阅列表为空，可前往图书馆借阅纸质书目。';

    return EmptyState(
      icon: Icons.auto_stories_outlined,
      title: '暂无借阅记录',
      message: hint,
    );
  }
}
