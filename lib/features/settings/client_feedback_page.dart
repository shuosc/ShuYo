import 'package:flutter/material.dart';

import '../../data/models/client_backend.dart';
import '../../data/repositories/client_backend_repository.dart';
import '../../data/services/student_identity_service.dart';
import '../../shared/compact_number.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/time_format.dart';
import '../../shared/widgets/empty_state.dart';
import 'student_identity_page.dart';

class ClientFeedbackPage extends StatefulWidget {
  const ClientFeedbackPage({
    super.key,
    required this.repository,
  });

  final ClientBackendRepository repository;

  @override
  State<ClientFeedbackPage> createState() => _ClientFeedbackPageState();
}

class _ClientFeedbackPageState extends State<ClientFeedbackPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contactController = TextEditingController();

  late Future<List<ClientFeedbackTicket>> _future;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _future = _loadTickets();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('问题与反馈'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _refresh(force: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<ClientFeedbackTicket>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.feedback_outlined,
              title: '加载失败',
              message: snapshot.error.toString(),
              action: TextButton.icon(
                onPressed: () => _refresh(force: true),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }

          final tickets = snapshot.data ?? const <ClientFeedbackTicket>[];
          final colors = context.shuyoColors;
          return RefreshIndicator(
            onRefresh: () => _refresh(force: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _ComposerCard(
                  formKey: _formKey,
                  titleController: _titleController,
                  contentController: _contentController,
                  contactController: _contactController,
                  submitting: _submitting,
                  onSubmit: () => _submit(),
                ),
                const SizedBox(height: 18),
                Text(
                  '我的反馈',
                  style: ShuYoTextStyles.sectionTitle(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                if (tickets.isEmpty)
                  const _EmptyTicketState()
                else
                  ...tickets.map(
                    (ticket) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _TicketTile(
                        ticket: ticket,
                        onTap: () => _openDetail(ticket),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openIdentity() async {
    final service = widget.repository.studentIdentityService;
    if (service == null) return;
    await Navigator.of(context).push<void>(
      shuyoRoute(builder: (_) => StudentIdentityPage(service: service)),
    );
    if (mounted) await _refresh(force: true);
  }

  Future<List<ClientFeedbackTicket>> _loadTickets() {
    return widget.repository.loadFeedbackTickets();
  }

  Future<void> _refresh({required bool force}) async {
    final future = force
        ? widget.repository.refreshFeedbackTickets()
        : widget.repository.loadFeedbackTickets();
    try {
      final tickets = await future;
      if (!mounted) {
        return;
      }
      setState(() {
        _future = Future.value(tickets);
      });
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '刷新失败：$error');
      }
    }
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    if (_submitting) {
      return;
    }

    setState(() => _submitting = true);
    try {
      await widget.repository.submitFeedback(
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
        contact: _contactController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      _contentController.clear();
      _titleController.clear();
      _showSnack(context, '反馈已提交');
      await _refresh(force: false);
    } on StudentIdentityException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('提交前请先完成身份验证'),
            action: SnackBarAction(label: '去验证', onPressed: _openIdentity),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '提交失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _openDetail(ClientFeedbackTicket ticket) async {
    await Navigator.of(context).push<void>(
      shuyoRoute(
        builder: (context) => ClientFeedbackDetailPage(
          repository: widget.repository,
          ticket: ticket,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await _refresh(force: false);
  }
}

class ClientFeedbackDetailPage extends StatefulWidget {
  const ClientFeedbackDetailPage({
    super.key,
    required this.repository,
    required this.ticket,
  });

  final ClientBackendRepository repository;
  final ClientFeedbackTicket ticket;

  @override
  State<ClientFeedbackDetailPage> createState() =>
      _ClientFeedbackDetailPageState();
}

class _ClientFeedbackDetailPageState extends State<ClientFeedbackDetailPage> {
  late Future<ClientFeedbackTicket> _future;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _future = Future.value(widget.ticket);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('反馈详情'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<ClientFeedbackTicket>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 3));
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.feedback_outlined,
              title: '加载失败',
              message: snapshot.error.toString(),
              action: TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }

          final ticket = snapshot.data!;
          final colors = context.shuyoColors;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _Section(
                  title: '反馈信息',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              ticket.title,
                              style: ShuYoTextStyles.title(
                                color: colors.textPrimary,
                                size: 16,
                                height: 1.24,
                                weight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _StatusBadge(status: ticket.status),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _MetaRow(
                          label: '提交时间',
                          value: TimeFormat.compact(ticket.createdAt)),
                      const SizedBox(height: 8),
                      _MetaRow(
                        label: '最近更新',
                        value: TimeFormat.compact(ticket.updatedAt),
                      ),
                      const SizedBox(height: 8),
                      _MetaRow(
                        label: '客户端版本',
                        value: _visibleVersion(ticket.appVersion),
                      ),
                      if (ticket.contact.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _MetaRow(label: '联系方式', value: ticket.contact),
                      ],
                    ],
                  ),
                ),
                if (ticket.lookupToken.isEmpty &&
                    ticket.status != 'closed') ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _refreshing ? null : () => _close(ticket),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('关闭这条反馈'),
                  ),
                ],
                const SizedBox(height: 14),
                _Section(
                  title: '内容',
                  child: Text(
                    ticket.content,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 14.5,
                      height: 1.46,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _Section(
                  title: '回复',
                  child: ticket.replies.isEmpty
                      ? Text(
                          '暂无回复',
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 13.5,
                          ),
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < ticket.replies.length; i++) ...[
                              _ReplyTile(reply: ticket.replies[i]),
                              if (i != ticket.replies.length - 1)
                                const SizedBox(height: 10),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      final current = await _future;
      final refreshed = await widget.repository.refreshFeedbackTicket(current);
      if (!mounted) {
        return;
      }
      setState(() {
        _future = Future.value(refreshed);
      });
    } on Object catch (error) {
      if (mounted) {
        _showSnack(context, '刷新失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _close(ClientFeedbackTicket ticket) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭反馈'),
        content: const Text('关闭后，这条反馈仍可查看，但你不能自行重新打开。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('关闭')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _refreshing = true);
    try {
      final closed = await widget.repository.closeFeedback(ticket);
      if (mounted) setState(() => _future = Future.value(closed));
    } on Object catch (error) {
      if (mounted) _showSnack(context, '关闭失败：$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }
}

class _ComposerCard extends StatelessWidget {
  const _ComposerCard({
    required this.formKey,
    required this.titleController,
    required this.contentController,
    required this.contactController,
    required this.submitting,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController titleController;
  final TextEditingController contentController;
  final TextEditingController contactController;
  final bool submitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '提交反馈',
              style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: titleController,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '标题',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: contentController,
              minLines: 5,
              maxLines: 8,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: '内容',
                alignLabelWithHint: true,
                counterText: '',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '请输入反馈内容';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: contactController,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '联系方式（可选）',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: submitting ? null : onSubmit,
                icon: submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : const Icon(Icons.send),
                label: const Text('提交'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  const _TicketTile({
    required this.ticket,
    required this.onTap,
  });

  final ClientFeedbackTicket ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          onTap: onTap,
          title: Text(
            ticket.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ShuYoTextStyles.title(
              color: colors.textPrimary,
              size: 15.5,
              height: 1.24,
              weight: FontWeight.w500,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ticket.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13.5,
                    height: 1.46,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SmallBadge(
                        text: ticket.lookupToken.isEmpty ? '认证反馈' : '旧版反馈'),
                    _SmallBadge(text: ticket.status),
                    _SmallBadge(text: TimeFormat.compact(ticket.updatedAt)),
                    if (ticket.replies.isNotEmpty)
                      _SmallBadge(
                          text: '${compactCount(ticket.replies.length)} 回复'),
                  ],
                ),
              ],
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.reply});

  final ClientFeedbackReply reply;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${reply.author} · ${TimeFormat.compact(reply.createdAt)}',
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            reply.message,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 14.5,
              height: 1.46,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 12.5,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '-' : value,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final color = switch (status) {
      'closed' => colors.danger,
      'replied' => colors.success,
      _ => colors.warning,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _EmptyTicketState extends StatelessWidget {
  const _EmptyTicketState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: EmptyState(
        icon: Icons.chat_bubble_outline,
        title: '暂无反馈',
        message: '提交后会显示在这里。',
      ),
    );
  }
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

String _visibleVersion(String value) {
  return value.split('+').first.trim();
}
