import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/library_constants.dart';
import '../../core/utils/library_author_parser.dart';
import '../../core/utils/library_book_citation.dart';
import '../../data/models/library_book_detail.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import '../../shared/theme/shuyo_theme.dart';
import 'library_author_text.dart';
import 'library_book_citation_bottom_sheet.dart';

class LibraryBookDetailPage extends StatefulWidget {
  const LibraryBookDetailPage({
    super.key,
    this.recordId,
    this.title,
    this.author,
    this.publisher,
    this.publishYear,
    this.coverUrl,
    this.apiClient,
    this.session,
  });

  final int? recordId;
  final String? title;
  final String? author;
  final String? publisher;
  final String? publishYear;
  final String? coverUrl;
  final LibraryApiClient? apiClient;
  final LibraryAuthSession? session;

  @override
  State<LibraryBookDetailPage> createState() => _LibraryBookDetailPageState();
}

class _LibraryBookDetailPageState extends State<LibraryBookDetailPage>
    with SingleTickerProviderStateMixin {
  late final LibraryApiClient _apiClient;
  late final TabController _tabController;

  LibraryBookDetailModel? _detailModel;
  bool _isLoading = false;
  bool _summaryExpanded = false;

  static const double _coverWidth = 92.0;
  static const double _coverHeight = 132.0;

  @override
  void initState() {
    super.initState();
    _apiClient = widget.apiClient ?? LibraryApiClient();
    _tabController = TabController(
      length: LibraryHoldingCampus.values.length,
      vsync: this,
    );
    _loadDetail();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    final recordId = widget.recordId;
    if (recordId == null) return;
    setState(() => _isLoading = true);

    try {
      final detailFuture = _apiClient.fetchBookDetail(
        recordId: recordId,
        session: widget.session,
      );
      final holdingsFuture = _apiClient.fetchRawBookHoldings(
        recordId: recordId,
        session: widget.session,
      );

      final results = await Future.wait([detailFuture, holdingsFuture]);
      final detailData = results[0] as Map<String, dynamic>? ?? const {};
      final holdingsData = results[1] as List<dynamic>? ?? const [];

      var cover = widget.coverUrl;
      final isbn = detailData['baseMarcInfoDto']?['isbn'] as String?;
      final bookTitle =
          detailData['baseMarcInfoDto']?['title'] as String? ?? widget.title;
      if (cover == null || cover.isEmpty) {
        cover = await _apiClient.fetchCoverUrl(
          isbn: isbn,
          title: bookTitle,
          recordId: recordId,
          session: widget.session,
        );
      }

      if (mounted) {
        setState(() {
          _detailModel = LibraryBookDetailModel.fromApiResponse(
            recordId: recordId,
            detailData: detailData,
            holdingsData: holdingsData,
            fallbackTitle: widget.title,
            fallbackAuthor: widget.author,
            fallbackPublisher: widget.publisher,
            fallbackPublishYear: widget.publishYear,
            coverUrl: cover,
          );
          _isLoading = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String get _externalUrl {
    final id = widget.recordId;
    if (id != null) {
      return '${LibraryConstants.baseUrl}/#/searchList/bookDetails/$id';
    }
    return '${LibraryConstants.baseUrl}/#/Home';
  }

  Future<void> _openExternal(String url) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // 容错处理
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开原网站链接')),
      );
    }
  }

  Future<void> _confirmOpenOriginal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳转浏览器'),
        content: const Text('将在浏览器中打开图书详情'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _openExternal(_externalUrl);
    }
  }

  LibraryBookCitation _getCitation() {
    final detail = _detailModel;
    final title = detail?.title ?? widget.title ?? '未知书名';
    final cleanAuthor = detail?.cleanAuthor;
    final author = detail?.author ?? widget.author;
    final publisher = detail?.publisher ?? widget.publisher;
    final publishYear = detail?.publishYear ?? widget.publishYear;
    final pubPlace = detail?.pubPlace;

    return LibraryBookCitation(
      title: title,
      author: author,
      cleanAuthor: cleanAuthor,
      publisher: publisher,
      pubPlace: pubPlace,
      publishYear: publishYear,
      docCode: 1,
    );
  }

  void _showCitationBottomSheet() {
    final citation = _getCitation();
    LibraryBookCitationBottomSheet.show(context, citation: citation);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;

    return Scaffold(
      appBar: AppBar(
        title: const Text('图书详情'),
        actions: [
          IconButton(
            tooltip: '引用',
            icon: const Icon(Icons.format_quote_rounded),
            onPressed: _showCitationBottomSheet,
          ),
          IconButton(
            tooltip: '查看原文',
            icon: const Icon(Icons.open_in_new),
            onPressed: _confirmOpenOriginal,
          ),
        ],
      ),
      body: _isLoading && _detailModel == null
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadDetail,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeaderSection(colors),
                          if (_detailModel?.summary != null &&
                              _detailModel!.summary!.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            _buildSummarySection(colors),
                          ],
                          const SizedBox(height: 22),
                          Text(
                            '馆藏分布',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _CampusStickyHeaderDelegate(
                      tabController: _tabController,
                      colors: colors,
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: _buildHoldingsSliver(colors),
                  ),
                  if (_detailModel?.metadataList.isNotEmpty == true)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 22, 16, 28),
                      sliver: SliverToBoxAdapter(
                        child: _buildMetadataSection(colors),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildHeaderSection(ShuYoColors colors) {
    final detail = _detailModel;
    final title = detail?.title ?? widget.title ?? '未知书名';
    final author = detail?.author ?? widget.author ?? '';
    final publisher = detail?.publisher ?? widget.publisher ?? '';
    final year = detail?.publishYear ?? widget.publishYear ?? '';
    final coverUrl = detail?.coverUrl ?? widget.coverUrl;
    final parsedAuthor = LibraryAuthorParser.parse(author);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCoverImage(colors, coverUrl),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              LibraryAuthorText(
                parsed: parsedAuthor,
                fallbackText: author,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                ),
                maxLines: 2,
              ),
              if (publisher.isNotEmpty || year.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  [
                    if (publisher.isNotEmpty) publisher,
                    if (year.isNotEmpty) '($year)',
                  ].join(' '),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.textMuted,
                  ),
                ),
              ],
              if (detail?.isbn != null && detail!.isbn!.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  'ISBN ${detail.isbn}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textMuted,
                  ),
                ),
              ],
              if (detail?.callNo != null && detail!.callNo!.isNotEmpty) ...[
                const SizedBox(height: 6),
                _buildCallNoChip(colors, detail.callNo!),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverImage(ShuYoColors colors, String? coverUrl) {
    final placeholder = Container(
      width: _coverWidth,
      height: _coverHeight,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: colors.textMuted,
          size: 32,
        ),
      ),
    );

    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        coverUrl,
        width: _coverWidth,
        height: _coverHeight,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return placeholder;
        },
      ),
    );
  }

  Widget _buildCallNoChip(ShuYoColors colors, String rawCallNo) {
    final parts = rawCallNo.split('/');
    final prefix = parts.first.trim();
    final suffix = parts.length > 1 ? parts.sublist(1).join('/').trim() : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '索书号 ',
          style: TextStyle(
            fontSize: 12,
            color: colors.textMuted,
          ),
        ),
        Text(
          prefix,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        if (suffix.isNotEmpty)
          Text(
            ' /$suffix',
            style: TextStyle(
              fontSize: 12,
              color: colors.textSecondary,
            ),
          ),
      ],
    );
  }

  Widget _buildSummarySection(ShuYoColors colors) {
    final summary = _detailModel?.summary ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '内容提要',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const Spacer(),
            if (summary.length > 120)
              GestureDetector(
                onTap: () =>
                    setState(() => _summaryExpanded = !_summaryExpanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    _summaryExpanded ? '收起' : '展开',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: colors.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          summary,
          style: TextStyle(
            fontSize: 13,
            height: 1.55,
            color: colors.textSecondary,
          ),
          maxLines: _summaryExpanded ? null : 3,
          overflow: _summaryExpanded ? null : TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildHoldingsSliver(ShuYoColors colors) {
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        final currentCampus = LibraryHoldingCampus.values[_tabController.index];
        final allHoldings = _detailModel?.holdings ?? const [];
        final holdings =
            allHoldings.where((h) => h.campus == currentCampus).toList();

        if (holdings.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Text(
                  '该校区暂无此藏书',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: colors.textMuted,
                  ),
                ),
              ),
            ),
          );
        }

        return SliverList.separated(
          itemCount: holdings.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: colors.border.withValues(alpha: 0.35),
          ),
          itemBuilder: (context, index) {
            final item = holdings[index];
            return _HoldingRow(
              colors: colors,
              item: item,
              index: index + 1,
            );
          },
        );
      },
    );
  }

  Widget _buildMetadataSection(ShuYoColors colors) {
    final list = _detailModel?.metadataList ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '书目元数据',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        for (final meta in list)
          _MetadataRow(
            colors: colors,
            item: meta,
          ),
      ],
    );
  }
}

/// 校区吸顶 Header Delegate
class _CampusStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _CampusStickyHeaderDelegate({
    required this.tabController,
    required this.colors,
  });

  final TabController tabController;
  final ShuYoColors colors;

  static const double _height = 42.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        height: _height,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(
            bottom: BorderSide(
              color:
                  colors.border.withValues(alpha: overlapsContent ? 0.6 : 0.25),
              width: 0.5,
            ),
          ),
        ),
        child: TabBar(
          controller: tabController,
          labelColor: colors.accent,
          unselectedLabelColor: colors.textSecondary,
          indicatorColor: colors.accent,
          indicatorWeight: 2.5,
          dividerColor: Colors.transparent,
          labelStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w400,
          ),
          tabs: [
            for (final campus in LibraryHoldingCampus.values)
              Tab(text: campus.label),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_CampusStickyHeaderDelegate oldDelegate) =>
      tabController != oldDelegate.tabController ||
      colors != oldDelegate.colors;
}

/// 馆藏状态图标与颜色映射辅助函数
(IconData, Color) _holdingStatusVisual(
    HoldingStatusCategory category, ShuYoColors colors) {
  switch (category) {
    case HoldingStatusCategory.onShelf:
      return (Icons.check_circle_outline_rounded, colors.accent);
    case HoldingStatusCategory.borrowed:
      return (Icons.schedule_rounded, colors.textSecondary);
    case HoldingStatusCategory.reshelving:
      return (Icons.sync_rounded, colors.accent);
    case HoldingStatusCategory.inTransit:
      return (Icons.local_shipping_outlined, colors.textSecondary);
    case HoldingStatusCategory.unavailable:
      return (Icons.remove_circle_outline_rounded, colors.textMuted);
  }
}

/// 单行馆藏信息条目（可点击裸列表，左侧序号，中间地点+订阅类型+索书号/应还，右侧文字+状态图标）
class _HoldingRow extends StatelessWidget {
  const _HoldingRow({
    required this.colors,
    required this.item,
    required this.index,
  });

  final ShuYoColors colors;
  final LibraryBookHoldingItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final location = item.cleanLocationName;
    final isBorrowed = item.statusCategory == HoldingStatusCategory.borrowed;
    final returnTime = item.dueDate;
    final (statusIcon, statusColor) =
        _holdingStatusVisual(item.statusCategory, colors);

    final itemPolicy = item.itemPolicyName;
    final hasSpecialPolicy = itemPolicy != null &&
        itemPolicy.isNotEmpty &&
        itemPolicy != '普通外借' &&
        itemPolicy != '普通';

    return InkWell(
      onTap: () {
        final buffer = StringBuffer();
        if (hasSpecialPolicy) buffer.write('[$itemPolicy] ');
        buffer.writeln(location);
        if (isBorrowed && returnTime != null) {
          buffer.writeln('应还日期: $returnTime');
        } else {
          buffer.writeln('索书号: ${item.callNo}');
        }
        if (item.barcode.isNotEmpty) buffer.writeln('条码: ${item.barcode}');
        buffer.write('状态: ${item.displayStatus}');
        Clipboard.setData(ClipboardData(text: buffer.toString()));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左侧序号（参照录播剧集序号风格）
            SizedBox(
              width: 28,
              child: Text(
                '$index',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textMuted,
                ),
              ),
            ),
            // 中间主要信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (hasSpecialPolicy) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: colors.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: colors.accent.withValues(alpha: 0.35),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            itemPolicy,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ],
                      Expanded(
                        child: Text(
                          location,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (isBorrowed && returnTime != null)
                        Text(
                          '应还 $returnTime',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: colors.textSecondary,
                          ),
                        )
                      else
                        Text(
                          '索书号 ${item.callNo}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      if (item.barcode.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Text(
                          '条码 ${item.barcode}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 右侧先文字，后状态图标（参照录播平台标准 20px / 22px 图标）
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.displayStatus,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  statusIcon,
                  size: 20,
                  color: statusColor,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 单行元数据条目（带一键复制功能）
class _MetadataRow extends StatefulWidget {
  const _MetadataRow({
    required this.colors,
    required this.item,
  });

  final ShuYoColors colors;
  final LibraryBookMetadataItem item;

  @override
  State<_MetadataRow> createState() => _MetadataRowState();
}

class _MetadataRowState extends State<_MetadataRow> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.item.value));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              widget.item.label,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              widget.item.value,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: _handleCopy,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _copied
                    ? Icon(
                        Icons.check_rounded,
                        key: const ValueKey('meta-checked'),
                        size: 15,
                        color: colors.textPrimary,
                      )
                    : Icon(
                        Icons.copy_rounded,
                        key: const ValueKey('meta-copy'),
                        size: 15,
                        color: colors.textMuted,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
