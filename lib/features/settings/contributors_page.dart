import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/github_contributor.dart';
import '../../data/services/github_contributors_service.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

class ContributorsPage extends StatefulWidget {
  const ContributorsPage({super.key, this.service});

  final GitHubContributorsService? service;

  @override
  State<ContributorsPage> createState() => _ContributorsPageState();
}

class _ContributorsPageState extends State<ContributorsPage> {
  late final GitHubContributorsService _service;
  late final bool _ownsService;
  List<GitHubContributor>? _contributors;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _ownsService = widget.service == null;
    _service = widget.service ?? GitHubContributorsService();
    _load();
  }

  @override
  void dispose() {
    if (_ownsService) _service.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final contributors = await _service.fetchContributors();
      if (mounted) setState(() => _contributors = contributors);
    } on Object catch (error) {
      if (!mounted) return;
      final message = error is GitHubContributorsException
          ? error.message
          : '贡献者信息加载失败，请重试';
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('贡献者')),
      body: _loading && _contributors == null
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _scrollableState(
        EmptyState(
          icon: Icons.cloud_off_outlined,
          title: '贡献者加载失败',
          message: error,
          action: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    final contributors = _contributors ?? const <GitHubContributor>[];
    if (contributors.isEmpty) {
      return _scrollableState(
        const EmptyState(
          icon: Icons.people_outline,
          title: '暂无贡献者',
          message: '暂未收录贡献者信息',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      itemCount: contributors.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) => _ContributorRow(
        contributor: contributors[index],
        onTap: () => _openProfile(contributors[index]),
      ),
    );
  }

  Widget _scrollableState(Widget child) {
    return CustomScrollView(
      slivers: [SliverFillRemaining(hasScrollBody: false, child: child)],
    );
  }

  Future<void> _openProfile(GitHubContributor contributor) async {
    try {
      final opened = await launchUrl(
        Uri.parse(contributor.profileUrl),
        mode: LaunchMode.externalApplication,
      );
      if (opened || !mounted) return;
    } on Object {
      if (!mounted) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开 GitHub 个人主页')),
      );
    }
  }
}

class _ContributorRow extends StatelessWidget {
  const _ContributorRow({required this.contributor, required this.onTap});

  final GitHubContributor contributor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final additions = contributor.additions;
    final deletions = contributor.deletions;
    final avatarUri = Uri.parse(contributor.avatarUrl);
    final avatarUrl = avatarUri.replace(queryParameters: {
      ...avatarUri.queryParameters,
      's': '128',
    }).toString();
    final avatarPlaceholder = ColoredBox(
      color: colors.surfaceMuted,
      child: SizedBox.square(
        dimension: 44,
        child: Icon(Icons.person_outline, color: colors.textMuted),
      ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipOval(
              child: Image.network(
                avatarUrl,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
                excludeFromSemantics: true,
                frameBuilder: (_, child, frame, wasSynchronouslyLoaded) =>
                    wasSynchronouslyLoaded || frame != null
                        ? child
                        : avatarPlaceholder,
                errorBuilder: (_, __, ___) => avatarPlaceholder,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        contributor.displayName,
                        style: ShuYoTextStyles.sectionTitle(
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        '@${contributor.login}',
                        style: ShuYoTextStyles.bodyCompact(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${contributor.commits} 次提交',
                        style: ShuYoTextStyles.meta(
                          color: colors.textSecondary,
                        ),
                      ),
                      if (additions != null && deletions != null) ...[
                        Text(
                          '+$additions',
                          semanticsLabel: '新增 $additions 行',
                          style: ShuYoTextStyles.meta(color: colors.success),
                        ),
                        Text(
                          '-$deletions',
                          semanticsLabel: '删除 $deletions 行',
                          style: ShuYoTextStyles.meta(color: colors.danger),
                        ),
                      ] else
                        Text(
                          contributor.statisticsMessage ?? '行数统计暂不可用',
                          style: ShuYoTextStyles.meta(color: colors.textMuted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.open_in_new, size: 18),
          ],
        ),
      ),
    );
  }
}
