import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/client_app_info.dart';
import '../../shared/navigation/shuyo_route.dart';
import '../../shared/shuyo_text_styles.dart';
import '../../shared/theme/shuyo_theme.dart';
import '../../shared/widgets/empty_state.dart';

class ThirdPartyLicensesPage extends StatefulWidget {
  const ThirdPartyLicensesPage({super.key, this.licenseLoader});

  final Stream<LicenseEntry> Function()? licenseLoader;

  @override
  State<ThirdPartyLicensesPage> createState() => _ThirdPartyLicensesPageState();
}

class _ThirdPartyLicensesPageState extends State<ThirdPartyLicensesPage> {
  List<_PackageLicenses>? _packages;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final entriesByPackage = <String, List<LicenseEntry>>{};
      String? firstPackage;
      final licenses = widget.licenseLoader?.call() ?? LicenseRegistry.licenses;
      await for (final entry in licenses) {
        if (!mounted) return;
        for (final package in entry.packages.toSet()) {
          firstPackage ??= package;
          entriesByPackage.putIfAbsent(package, () => []).add(entry);
        }
      }
      final packages = entriesByPackage.entries
          .map((entry) => _PackageLicenses(entry.key, entry.value))
          .toList()
        ..sort((first, second) {
          if (first.name == second.name) return 0;
          // Match Flutter's license page: keep the first registered package
          // (normally the application) ahead of the alphabetized dependencies.
          if (first.name == firstPackage) return -1;
          if (second.name == firstPackage) return 1;
          final order = first.name.toLowerCase().compareTo(
                second.name.toLowerCase(),
              );
          return order == 0 ? first.name.compareTo(second.name) : order;
        });
      if (mounted) setState(() => _packages = packages);
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('第三方开源许可')),
      body: SafeArea(top: false, child: _buildContent(context)),
    );
  }

  Widget _buildContent(BuildContext context) {
    return _LicenseScrollbar(
      builder: (controller) => CustomScrollView(
        controller: controller,
        primary: false,
        slivers: [
          const SliverToBoxAdapter(child: _LicenseApplicationHeader()),
          ..._buildLicenseSlivers(context),
        ],
      ),
    );
  }

  List<Widget> _buildLicenseSlivers(BuildContext context) {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_failed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.error_outline,
            title: '许可信息加载失败',
            message: '无法读取第三方开源许可，请重试',
            action: TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
        )
      ];
    }
    final packages = _packages ?? const <_PackageLicenses>[];
    if (packages.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.description_outlined,
            title: '暂无第三方许可',
            message: '当前构建未收录第三方开源许可信息',
          ),
        )
      ];
    }
    final colors = context.shuyoColors;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        sliver: SliverList.separated(
          itemCount: packages.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final package = packages[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                package.name,
                style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary),
              ),
              subtitle: Text(
                '${package.entries.length} 项许可',
                style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).push<void>(
                shuyoRoute(
                  builder: (_) => _PackageLicensePage(package: package),
                ),
              ),
            );
          },
        ),
      )
    ];
  }
}

class _LicenseApplicationHeader extends StatelessWidget {
  const _LicenseApplicationHeader();

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/images/icon_light.png',
              width: 48,
              height: 48,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            ClientAppInfo.appName,
            textAlign: TextAlign.center,
            style: ShuYoTextStyles.pageTitle(color: colors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            '版本 ${ClientAppInfo.version}（${ClientAppInfo.buildNumber}）',
            textAlign: TextAlign.center,
            style: ShuYoTextStyles.bodyCompact(color: colors.textTertiary),
          ),
          const SizedBox(height: 12),
          Text(
            'Powered by Flutter',
            textAlign: TextAlign.center,
            style: ShuYoTextStyles.meta(color: colors.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _PackageLicenses {
  _PackageLicenses(this.name, List<LicenseEntry> entries)
      : entries = List.unmodifiable(entries);

  final String name;
  final List<LicenseEntry> entries;
  Future<List<LicenseParagraph?>>? _paragraphs;

  Future<List<LicenseParagraph?>> loadParagraphs() {
    return _paragraphs ??= _readParagraphs();
  }

  Future<List<LicenseParagraph?>> _readParagraphs() async {
    try {
      final result = <LicenseParagraph?>[];
      for (final entry in entries) {
        // Font and dependency licenses can contain long texts. Parse only the
        // selected package and let the scheduler coordinate work between entries.
        final paragraphs = await SchedulerBinding.instance.scheduleTask(
          () => entry.paragraphs.toList(growable: false),
          Priority.animation,
          debugLabel: 'Parse third-party license',
        );
        if (result.isNotEmpty && paragraphs.isNotEmpty) result.add(null);
        result.addAll(paragraphs);
      }
      return List.unmodifiable(result);
    } on Object {
      _paragraphs = null;
      rethrow;
    }
  }
}

class _PackageLicensePage extends StatefulWidget {
  const _PackageLicensePage({required this.package});

  final _PackageLicenses package;

  @override
  State<_PackageLicensePage> createState() => _PackageLicensePageState();
}

class _PackageLicensePageState extends State<_PackageLicensePage> {
  late Future<List<LicenseParagraph?>> _paragraphs;

  @override
  void initState() {
    super.initState();
    _paragraphs = widget.package.loadParagraphs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.package.name)),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<LicenseParagraph?>>(
          future: _paragraphs,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _LicenseState(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: '许可正文加载失败',
                  message: '无法读取此软件包的许可正文，请重试',
                  action: TextButton.icon(
                    onPressed: () => setState(() {
                      _paragraphs = widget.package.loadParagraphs();
                    }),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ),
              );
            }
            final paragraphs = snapshot.data!;
            return _LicenseScrollbar(
              builder: (controller) => ListView.builder(
                controller: controller,
                primary: false,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                itemCount: paragraphs.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${widget.package.entries.length} 项许可',
                        style: ShuYoTextStyles.meta(
                          color: context.shuyoColors.textTertiary,
                        ),
                      ),
                    );
                  }
                  final paragraph = paragraphs[index - 1];
                  if (paragraph == null) return const Divider(height: 32);
                  final centered =
                      paragraph.indent == LicenseParagraph.centeredIndent;
                  return Padding(
                    padding: EdgeInsetsDirectional.only(
                      top: centered ? 16 : 8,
                      start: centered ? 0 : 16.0 * paragraph.indent,
                    ),
                    child: SelectableText(
                      paragraph.text,
                      textAlign: centered ? TextAlign.center : TextAlign.start,
                      style: ShuYoTextStyles.bodyCompact(
                        color: context.shuyoColors.textPrimary,
                        height: 1.5,
                        weight: centered ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LicenseState extends StatelessWidget {
  const _LicenseState({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _LicenseScrollbar(
      builder: (controller) => CustomScrollView(
        controller: controller,
        primary: false,
        slivers: [SliverFillRemaining(hasScrollBody: false, child: child)],
      ),
    );
  }
}

class _LicenseScrollbar extends StatefulWidget {
  const _LicenseScrollbar({required this.builder});

  final Widget Function(ScrollController controller) builder;

  @override
  State<_LicenseScrollbar> createState() => _LicenseScrollbarState();
}

class _LicenseScrollbarState extends State<_LicenseScrollbar> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: true,
        child: widget.builder(_controller),
      ),
    );
  }
}
