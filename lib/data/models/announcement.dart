import 'common.dart';
import 'announcement_source.dart';

enum AnnouncementContentType {
  text,
  image,
  link,
  table,
}

class AnnouncementTableCell {
  const AnnouncementTableCell({
    required this.row,
    required this.column,
    required this.text,
    this.rowSpan = 1,
    this.columnSpan = 1,
    this.textAlignment = 'left',
    this.verticalAlignment = 'middle',
  });

  final int row;
  final int column;
  final String text;
  final int rowSpan;
  final int columnSpan;
  final String textAlignment;
  final String verticalAlignment;

  JsonMap toJson() => {
        'row': row,
        'column': column,
        'text': text,
        'rowSpan': rowSpan,
        'columnSpan': columnSpan,
        'textAlignment': textAlignment,
        'verticalAlignment': verticalAlignment,
      };

  factory AnnouncementTableCell.fromJson(JsonMap json) => AnnouncementTableCell(
        row: intValue(json['row']),
        column: intValue(json['column']),
        text: stringValue(json['text']),
        rowSpan: intValue(json['rowSpan'], 1),
        columnSpan: intValue(json['columnSpan'], 1),
        textAlignment: stringValue(json['textAlignment']).isEmpty
            ? 'left'
            : stringValue(json['textAlignment']),
        verticalAlignment: stringValue(json['verticalAlignment']).isEmpty
            ? 'middle'
            : stringValue(json['verticalAlignment']),
      );
}

class AnnouncementContentBlock {
  const AnnouncementContentBlock.text(this.value)
      : type = AnnouncementContentType.text,
        alt = '',
        label = '',
        rows = const [],
        cells = const [];

  const AnnouncementContentBlock.image(
    this.value, {
    this.alt = '',
  })  : type = AnnouncementContentType.image,
        label = '',
        rows = const [],
        cells = const [];

  const AnnouncementContentBlock.link(this.value, {required this.label})
      : type = AnnouncementContentType.link,
        alt = '',
        rows = const [],
        cells = const [];

  const AnnouncementContentBlock.table(this.rows)
      : type = AnnouncementContentType.table,
        value = '',
        alt = '',
        label = '',
        cells = const [];

  const AnnouncementContentBlock.structuredTable({
    required this.rows,
    required this.cells,
  })  : type = AnnouncementContentType.table,
        value = '',
        alt = '',
        label = '';

  final AnnouncementContentType type;
  final String value;
  final String alt;
  final String label;
  final List<List<String>> rows;
  final List<AnnouncementTableCell> cells;

  bool get isText => type == AnnouncementContentType.text;
  bool get isImage => type == AnnouncementContentType.image;
  bool get isLink => type == AnnouncementContentType.link;
  bool get isTable => type == AnnouncementContentType.table;

  JsonMap toJson() {
    return {
      'type': type.name,
      'value': value,
      'alt': alt,
      'label': label,
      'rows': rows,
      'cells': cells.map((cell) => cell.toJson()).toList(),
    };
  }

  factory AnnouncementContentBlock.fromJson(JsonMap json) {
    final type = stringValue(json['type']);
    final value = stringValue(json['value']);
    if (type == AnnouncementContentType.image.name) {
      return AnnouncementContentBlock.image(
        value,
        alt: stringValue(json['alt']),
      );
    }
    if (type == AnnouncementContentType.link.name) {
      return AnnouncementContentBlock.link(
        value,
        label: stringValue(json['label']),
      );
    }
    if (type == AnnouncementContentType.table.name) {
      final rows = (json['rows'] as List? ?? const [])
          .whereType<List>()
          .map((row) => row.map((cell) => cell.toString()).toList())
          .toList();
      final cells = (json['cells'] as List? ?? const [])
          .whereType<Map>()
          .map((cell) => AnnouncementTableCell.fromJson(
                cell.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .toList();
      if (cells.isNotEmpty) {
        return AnnouncementContentBlock.structuredTable(
          rows: rows,
          cells: cells,
        );
      }
      return AnnouncementContentBlock.table(rows);
    }
    return AnnouncementContentBlock.text(value);
  }
}

class AnnouncementListItem {
  const AnnouncementListItem({
    required this.title,
    required this.url,
    this.summary = '',
    this.dateText = '',
    this.publishedAt,
    this.sourceId = AnnouncementSource.officialId,
    this.column = '',
  });

  final String title;
  final String url;
  final String summary;
  final String dateText;
  final DateTime? publishedAt;
  final String sourceId;
  final String column;

  JsonMap toJson() {
    return {
      'title': title,
      'url': url,
      'summary': summary,
      'dateText': dateText,
      'publishedAt': publishedAt?.toIso8601String(),
      'sourceId': sourceId,
      'column': column,
    };
  }

  factory AnnouncementListItem.fromJson(JsonMap json) {
    return AnnouncementListItem(
      title: stringValue(json['title']),
      url: stringValue(json['url']),
      summary: stringValue(json['summary']),
      dateText: stringValue(json['dateText']),
      publishedAt: dateValue(json['publishedAt']),
      sourceId: stringValue(json['sourceId']).isEmpty
          ? AnnouncementSource.officialId
          : stringValue(json['sourceId']),
      column: stringValue(json['column']),
    );
  }
}

class AnnouncementDetail {
  const AnnouncementDetail({
    required this.title,
    required this.url,
    required this.blocks,
    this.dateText = '',
    this.publishedAt,
    this.author = '',
    this.department = '',
  });

  final String title;
  final String url;
  final List<AnnouncementContentBlock> blocks;
  final String dateText;
  final DateTime? publishedAt;
  final String author;
  final String department;

  bool get hasContent => blocks.isNotEmpty;
}
