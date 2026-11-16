import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/theme/shuyo_theme.dart';

const libraryRulesAsset = 'assets/library_booking/rules.md';
const libraryQaAsset = 'assets/library_booking/QA.md';
const librarySeatsAsset = 'assets/library_booking/seats.jpg';
const libraryMapAsset = 'assets/library_booking/lib_map.jpg';

class LibraryBookingInfoPage extends StatefulWidget {
  const LibraryBookingInfoPage({
    super.key,
    required this.title,
    required this.asset,
  });

  final String title;
  final String asset;

  @override
  State<LibraryBookingInfoPage> createState() => _LibraryBookingInfoPageState();
}

class _LibraryBookingInfoPageState extends State<LibraryBookingInfoPage> {
  late final Future<String> _content = rootBundle.loadString(widget.asset);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: FutureBuilder<String>(
          future: _content,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('内容暂时无法打开'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
              children: _article(context, snapshot.data!),
            );
          },
        ),
      );

  List<Widget> _article(BuildContext context, String source) {
    final blocks = <Widget>[];
    final paragraph = <String>[];
    final isQa = widget.asset == libraryQaAsset;
    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_paragraph(context, paragraph, emphasizeLabels: isQa));
      paragraph.clear();
    }

    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (index == 0 && line == '# ${widget.title}') continue;
      if (line.isEmpty) {
        flushParagraph();
        continue;
      }
      if (line.startsWith('# ')) {
        flushParagraph();
        blocks.add(_section(context, line.substring(2)));
        continue;
      }
      if (line.startsWith('## ')) {
        flushParagraph();
        blocks.add(isQa
            ? _section(context, line.substring(3))
            : _subsection(context, line.substring(3)));
        continue;
      }
      if (line.startsWith('### ')) {
        flushParagraph();
        blocks.add(_subsection(context, line.substring(4)));
        continue;
      }
      final image = RegExp(r'^!\[.*?\]\(([^)]+)\)$').firstMatch(line);
      if (image != null) {
        flushParagraph();
        if (image.group(1) == 'lib_map.jpg') {
          blocks.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: InkWell(
              onTap: () => showLibraryBookingImage(context, libraryMapAsset),
              child: Image.asset(libraryMapAsset, fit: BoxFit.contain),
            ),
          ));
        }
        continue;
      }
      final numbered = RegExp(r'^(\d+)\.\s*(.+)$').firstMatch(line);
      if (numbered != null) {
        flushParagraph();
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 26,
                child:
                    Text('${numbered.group(1)}.', style: _bodyStyle(context))),
            Expanded(
                child: SelectableText(numbered.group(2)!,
                    style: _bodyStyle(context))),
          ]),
        ));
        continue;
      }
      paragraph.add(line);
    }
    flushParagraph();
    return blocks;
  }

  TextStyle _bodyStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyLarge!.copyWith(
            color: context.shuyoColors.textPrimary,
            fontSize: 15.5,
            height: 1.5,
            fontWeight: FontWeight.w400,
          );

  Widget _section(BuildContext context, String title) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 7),
      child: Row(children: [
        Container(width: 3, height: 19, color: colors.accent),
        const SizedBox(width: 9),
        Expanded(
            child: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 18.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
        )),
      ]),
    );
  }

  Widget _subsection(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: 16.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
              ),
        ),
      );

  Widget _paragraph(BuildContext context, List<String> lines,
      {required bool emphasizeLabels}) {
    final spans = <TextSpan>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (index > 0) spans.add(const TextSpan(text: '\n'));
      final colon = emphasizeLabels ? line.indexOf('：') : -1;
      if (colon > 0 && colon < 24) {
        spans.add(TextSpan(
            text: line.substring(0, colon + 1),
            style: const TextStyle(fontWeight: FontWeight.w500)));
        spans.add(TextSpan(text: line.substring(colon + 1)));
      } else {
        spans.add(TextSpan(text: line));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText.rich(TextSpan(children: spans),
          style: _bodyStyle(context)),
    );
  }
}

Future<void> showLibraryBookingImage(BuildContext context, String asset) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭图片',
      barrierColor: Colors.black.withValues(alpha: 0.76),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, __) => Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5,
                child: Center(
                  child: Image.asset(asset, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: '关闭图片',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: dialogContext.shuyoColors.surface,
                  foregroundColor: dialogContext.shuyoColors.textPrimary,
                ),
              ),
            ),
          ]),
        ),
      ),
      transitionBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    );
