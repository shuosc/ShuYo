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

class _LibraryBookDetailPageState extends State<LibraryBookDetailPage> {
  late final LibraryApiClient _apiClient;
  LibraryBookDetailModel? _detailModel;
  bool _isLoading = false;
  bool _summaryExpanded = false;

  static const double _coverWidth = 92.0;
  static const double _coverHeight = 132.0;

  @override
  void initState() {
    super.initState();
    _apiClient = widget.apiClient ?? LibraryApiClient();
    _loadDetail();
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
      final bookTitle = detailData['baseMarcInfoDto']?['title'] as String? ?? widget.title;
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
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                children: [
                  _buildHeaderSection(colors),
                  if (_detailModel?.summary != null &&
                      _detailModel!.summary!.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _buildSummarySection(colors),
                  ],
                  const SizedBox(height: 22),
                  _buildHoldingsSection(colors),
                  if (_detailModel?.metadataList.isNotEmpty == true) ...[
                    const SizedBox(height: 22),
                    _buildMetadataSection(colors),
                  ],
                  const SizedBox(height: 28),
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
                onTap: () => setState(() => _summaryExpanded = !_summaryExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
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

  Widget _buildHoldingsSection(ShuYoColors colors) {
    final holdings = _detailModel?.holdings ?? const [];
    final onShelfCount = _detailModel?.onShelfHoldings ?? 0;
    final totalCount = _detailModel?.totalHoldings ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '馆藏分布',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            if (totalCount > 0)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$onShelfCount',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.accent,
                      ),
                    ),
                    TextSpan(
                      text: '/$totalCount本可借',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (holdings.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无在架馆藏单册信息',
              style: TextStyle(
                fontSize: 13,
                color: colors.textMuted,
              ),
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: holdings.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = holdings[index];
              return _HoldingRow(colors: colors, item: item);
            },
          ),
      ],
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

/// 单行馆藏信息条目（非包裹卡片，纯粹的极简行布局）
class _HoldingRow extends StatelessWidget {
  const _HoldingRow({
    required this.colors,
    required this.item,
  });

  final ShuYoColors colors;
  final LibraryBookHoldingItem item;

  @override
  Widget build(BuildContext context) {
    final isOnShelf = item.isOnShelf;
    final location = item.curLocationName?.isNotEmpty == true
        ? item.curLocationName!
        : item.locationName;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isOnShelf
                  ? colors.accent.withValues(alpha: 0.12)
                  : colors.surfaceAlt,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isOnShelf
                    ? colors.accent.withValues(alpha: 0.3)
                    : colors.border.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              item.processType.isNotEmpty ? item.processType : (isOnShelf ? '在架' : '借出'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isOnShelf ? colors.accent : colors.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  location,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '索书号 ${item.callNo}',
                      style: TextStyle(
                        fontSize: 11.5,
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
          if (item.itemPolicyName != null && item.itemPolicyName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                item.itemPolicyName!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: colors.textMuted,
                ),
              ),
            ),
        ],
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
