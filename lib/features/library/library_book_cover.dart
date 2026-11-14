import 'package:flutter/material.dart';

import '../../core/library_constants.dart';
import '../../shared/theme/shuyo_theme.dart';

/// 图书馆图书封面组件：优先展示读秀/真实封面，缺失或加载失败时复刻 Web 端
/// （`static12.libsp.cn/static/img/index{1..4}.jpg` + 书名/出版社排版）的封面样式。
class LibraryBookCover extends StatelessWidget {
  const LibraryBookCover({
    super.key,
    required this.recordId,
    required this.title,
    this.publisher,
    this.coverUrl,
    required this.width,
    required this.height,
    this.borderRadius = 6.0,
    this.isLarge = false,
  });

  final int recordId;
  final String title;
  final String? publisher;
  final String? coverUrl;
  final double width;
  final double height;
  final double borderRadius;
  final bool isLarge;

  @override
  Widget build(BuildContext context) {
    final fallback = _WebGeneratedCover(
      recordId: recordId,
      title: title,
      publisher: publisher,
      width: width,
      height: height,
      borderRadius: borderRadius,
      isLarge: isLarge,
    );

    final trimmed = coverUrl?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        trimmed,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return fallback;
        },
      ),
    );
  }
}

class _WebGeneratedCover extends StatelessWidget {
  const _WebGeneratedCover({
    required this.recordId,
    required this.title,
    this.publisher,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.isLarge,
  });

  final int recordId;
  final String title;
  final String? publisher;
  final double width;
  final double height;
  final double borderRadius;
  final bool isLarge;

  String get _displayTitle {
    final clean = title.trim();
    if (clean.length <= 15) return clean;
    return clean.substring(0, 15);
  }

  String get _displayPublisher {
    final clean = (publisher ?? '').trim();
    if (clean.length <= 10) return clean;
    return clean.substring(0, 10);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final templateUrl = LibraryConstants.webFallbackCoverUrl(recordId);
    final displayTitle = _displayTitle;
    final displayPublisher = _displayPublisher;

    final staticFallback = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              templateUrl,
              key: ValueKey('library-web-fallback-cover:$recordId'),
              width: width,
              height: height,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => staticFallback,
            ),
            if (displayTitle.isNotEmpty)
              Positioned(
                left: width * 0.08,
                right: width * 0.08,
                top: 0,
                height: height * 0.30,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ExcludeSemantics(
                    child: Text(
                      displayTitle,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isLarge ? 10.5 : 8.0,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF333333),
                      ),
                    ),
                  ),
                ),
              ),
            if (displayPublisher.isNotEmpty)
              Positioned(
                left: width * 0.10,
                right: width * 0.10,
                bottom: 0,
                height: height * 0.15,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ExcludeSemantics(
                    child: Text(
                      displayPublisher,
                      textAlign: TextAlign.left,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isLarge ? 8.0 : 5.8,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF7A7A7A),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
