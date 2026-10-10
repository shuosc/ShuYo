import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/services/student_identity_service.dart';

class StudentIdentityPage extends StatefulWidget {
  const StudentIdentityPage({super.key, required this.service});

  final StudentIdentityService service;

  @override
  State<StudentIdentityPage> createState() => _StudentIdentityPageState();
}

class _StudentIdentityPageState extends State<StudentIdentityPage> {
  late Future<StudentIdentitySession?> _session = _load();
  bool _busy = false;
  String? _message;

  Future<StudentIdentitySession?> _load() async {
    try {
      return await widget.service.checkCurrentSession();
    } on Object {
      return widget.service.loadLocalSession();
    }
  }

  void _refresh() {
    if (mounted) {
      setState(() {
        _session = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('认证状态')),
      body: FutureBuilder<StudentIdentitySession?>(
        future: _session,
        builder: (context, snapshot) {
          if (!snapshot.hasData &&
              snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final session = snapshot.data;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                  session == null ? '未认证' : '已认证 · ${session.maskedStudentId}'),
              if (session == null) ...[
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _verify,
                  child: const Text('尝试认证'),
                ),
              ],
              if (session != null) ...[
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _busy ? null : _signOut,
                  child: const Text('撤销当前设备的认证'),
                ),
                TextButton(
                  onPressed: _busy ? null : _revokeAll,
                  child: const Text('撤销全部设备的认证'),
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(_message!),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await widget.service.hasConsent()) {
        if (!mounted || !await _confirmIdentityConsent()) return;
        await widget.service.grantConsent();
      }
      await widget.service.bindCurrentStudent(manual: true);
      if (mounted) setState(() => _message = '身份已认证');
      _refresh();
    } on Object {
      StudentIdentitySession? confirmed;
      try {
        confirmed = await widget.service.checkCurrentSession();
      } on Object {
        // The original failure remains the result when the follow-up check
        // cannot establish a valid session.
      }
      if (mounted) {
        setState(() =>
            _message = confirmed == null ? '当前暂时无法验证您的身份，请稍后再试' : '身份已认证');
        if (confirmed != null) _refresh();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmIdentityConsent() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('身份验证'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '为避免身份冒用，ShuYo将验证你的校园身份，认证后可使用分享课程表、课程评价等功能。',
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://shuyo.work/doc/privacy.html'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('隐私政策'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('暂不'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await widget.service.signOut();
      if (mounted) setState(() => _message = '当前设备的认证已撤销。');
      _refresh();
    } on Object {
      if (mounted) setState(() => _message = '撤销失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeAll() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('撤销全部设备的认证？'),
            content: const Text('所有设备的认证都会失效。之后需要手动重新认证，才能使用相关功能。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认撤销'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.service.revokeAllDevices();
      if (mounted) setState(() => _message = '全部设备的认证已撤销。');
      _refresh();
    } on StudentIdentityException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on Object {
      if (mounted) setState(() => _message = '操作失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
