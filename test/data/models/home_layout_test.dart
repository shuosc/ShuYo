import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/home_layout.dart';

void main() {
  test('default layout separates the token and places a divider after courses',
      () {
    expect(HomeLayout.defaults().entries.map((entry) => entry.key), [
      'group:overview',
      'module:today_course',
      'divider:overview-divider',
      'module:campus_card',
      'module:announcements',
      'module:empty_classroom',
      'module:course_recordings',
      'module:library_booking',
      'module:campus_map',
      'group:services',
      'module:otp',
    ]);
  });

  test('moving a module across a group boundary preserves hidden state', () {
    final initial =
        HomeLayout.defaults().setEnabled(HomeModule.campusCard, false);
    final moved = initial.move(1, initial.entries.length - 1);
    expect(moved.visibleGroups.first.modules, [
      HomeModule.announcements,
      HomeModule.emptyClassroom,
      HomeModule.courseRecordings,
      HomeModule.libraryBooking,
      HomeModule.campusMap,
    ]);
    expect(moved.visibleGroups.last.modules.last, HomeModule.todayCourse);
    expect(
        moved.entries
            .singleWhere((e) => e.module == HomeModule.campusCard)
            .enabled,
        isFalse);
    expect(moved.entries.where((e) => e.isModule),
        hasLength(HomeModule.values.length));
  });

  test('removing a group merges its modules without losing them', () {
    final merged = HomeLayout.defaults().removeGroup('services');
    expect(merged.visibleGroups, hasLength(1));
    expect(merged.visibleGroups.single.modules, HomeModule.values);
    final ungrouped = merged.removeGroup('overview');
    expect(ungrouped.visibleGroups.single.id, 'ungrouped');
    expect(ungrouped.visibleGroups.single.modules, HomeModule.values);
  });

  test('an empty card is omitted and fully hidden modules remain recoverable',
      () {
    var layout = HomeLayout.defaults().addGroup('empty').addDivider('line');
    for (final module in HomeModule.values) {
      layout = layout.setEnabled(module, false);
    }
    final restored = HomeLayout.fromJson(layout.toJson());
    expect(restored.visibleGroups, isEmpty);
    expect(restored.entries.where((e) => e.isModule),
        hasLength(HomeModule.values.length));
    expect(
        restored.setEnabled(HomeModule.otp, true).visibleGroups.single.modules,
        [HomeModule.otp]);
  });

  test('older layouts gain missing modules without resetting customization',
      () {
    final layout = HomeLayout.fromJson({
      'version': 1,
      'entries': [
        {'type': 'group', 'id': 'overview', 'title': '我的概览'},
        {'type': 'module', 'id': 'campus_card', 'enabled': false},
        {'type': 'module', 'id': 'retired_feature', 'enabled': true},
        {'type': 'module', 'id': 'campus_card', 'enabled': true},
        {'type': 'group', 'id': 'services', 'title': '常用工具'},
        {'type': 'group', 'id': 'services', 'title': '重复分组'},
        {'type': 'module', 'id': 'otp', 'enabled': true},
        'invalid entry',
      ],
    });
    expect(layout.entries.where((e) => e.isGroup), hasLength(2));
    expect(layout.entries.where((e) => e.isModule),
        hasLength(HomeModule.values.length));
    expect(layout.entries[1].module, HomeModule.campusCard);
    expect(layout.entries[1].enabled, isFalse);
    expect(layout.visibleGroups.first.id, 'overview');
    expect(layout.visibleGroups.first.modules, [
      HomeModule.todayCourse,
      HomeModule.announcements,
      HomeModule.emptyClassroom,
      HomeModule.courseRecordings,
      HomeModule.libraryBooking,
      HomeModule.campusMap,
    ]);
    expect(layout.visibleGroups.last.modules.first, HomeModule.otp);
  });

  test('an explicit divider keeps its position through hiding and persistence',
      () {
    final initial =
        HomeLayout.defaults().setEnabled(HomeModule.campusCard, false);
    var layout = initial.addDivider('line');
    layout = layout.move(layout.entries.length - 1, 3);
    final restored = HomeLayout.fromJson(layout.toJson());
    expect(restored.toJson(), layout.toJson());
    expect(restored.visibleGroups.first.entries.map((entry) => entry.key), [
      'module:today_course',
      'divider:overview-divider',
      'divider:line',
      'module:announcements',
      'module:empty_classroom',
      'module:course_recordings',
      'module:library_booking',
      'module:campus_map',
    ]);
    final withoutLine = restored.removeDivider('line');
    expect(withoutLine.toJson(), initial.toJson());
    expect(withoutLine.entries.where((entry) => entry.isGroup), hasLength(2));
  });

  test('duplicate or malformed dividers do not duplicate keys or lose modules',
      () {
    final json = HomeLayout.defaults().toJson();
    json['entries'] = <Object?>[
      ...(json['entries']! as List),
      {'type': 'divider', 'id': 'line'},
      {'type': 'divider', 'id': 'line'},
      {'type': 'divider', 'id': ''},
      {'type': 'divider', 'id': 42},
    ];
    final restored = HomeLayout.fromJson(json);
    expect(
        restored.entries
            .where((entry) => entry.isDivider)
            .map((entry) => entry.dividerId),
        ['overview-divider', 'line']);
    expect(restored.entries.where((entry) => entry.isModule),
        hasLength(HomeModule.values.length));
  });

  test('invalid or unsupported configuration falls back to default groups', () {
    for (final invalid in [
      null,
      [],
      {'version': 2, 'entries': []},
      {
        'version': 1,
        'entries': [false, {}]
      },
    ]) {
      expect(HomeLayout.fromJson(invalid).toJson(),
          HomeLayout.defaults().toJson());
    }
  });
}
