import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/library_constants.dart';
import '../../core/utils/library_book_citation.dart';
import '../../data/services/library_api_client.dart';
import '../../data/services/library_auth_service.dart';
import 'library_book_citation_bottom_sheet.dart';

class LibraryBookDetailPage extends StatefulWidget {
  const LibraryBookDetailPage({
    super.key,
    this.recordId,
    this.title,
    this.author,
    this.publisher,
    this.publishYear,
    this.apiClient,
    this.session,
  });

  final int? recordId;
  final String? title;
  final String? author;
  final String? publisher;
  final String? publishYear;
  final LibraryApiClient? apiClient;
  final LibraryAuthSession? session;

  @override
  State<LibraryBookDetailPage> createState() => _LibraryBookDetailPageState();
}

class _LibraryBookDetailPageState extends State<LibraryBookDetailPage> {
  late final LibraryApiClient _apiClient;
  Map<String, dynamic>? _detailData;
  bool _isLoading = false;

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
      final data = await _apiClient.fetchBookDetail(
        recordId: recordId,
        session: widget.session,
      );
      if (mounted) {
        setState(() {
          _detailData = data;
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
    final baseMarc = _detailData?['baseMarcInfoDto'] as Map<String, dynamic>?;
    final title = baseMarc?['title'] as String? ?? widget.title ?? '未知书名';
    final cleanAuthor = baseMarc?['cleanAuthor'] as String?;
    final author = baseMarc?['author'] as String? ?? widget.author;
    final publisher = baseMarc?['publisher'] as String? ?? widget.publisher;
    final publishYear =
        baseMarc?['publishYear'] as String? ?? widget.publishYear;
    final pubPlace = baseMarc?['pubPlace'] as String?;

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
      body: _isLoading
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const SizedBox.expand(),
    );
  }
}
