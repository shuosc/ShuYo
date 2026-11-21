import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/models/classroom.dart';

const _selection = {3, 4, 7, 8};
const _gap = ClassroomCourse(
  courseName: '线性代数',
  teacherName: '李老师',
  startSection: 5,
  endSection: 6,
);
const _booking = ClassroomCourse(
  courseName: '教学活动',
  teacherName: '',
  startSection: 4,
  endSection: 7,
  source: '借',
);

ClassroomRoom _room(int id, List<ClassroomCourse> courses) => ClassroomRoom(
      id: id,
      name: 'A10$id',
      floorName: '一层',
      fullName: '',
      courses: courses,
    );

void main() {
  test('availability checks every selected section but skips the gap', () {
    final gapOnly = _room(1, [_gap]);
    final occupied = _room(2, [_booking]);
    final empty = _room(3, []);
    final floor = ClassroomFloor(
      id: 1,
      name: '一层',
      rooms: [gapOnly, occupied, empty],
    );

    expect(ClassroomFloorAvailability(floor, _selection).availableRooms,
        [gapOnly, empty]);
    expect(gapOnly.isFreeFor({3, 4, 5, 6, 7, 8}), isFalse);
    expect(empty.isFreeFor({}), isFalse);
  });

  test('an arrangement overlapping multiple selected sections appears once',
      () {
    final room = _room(1, [_gap, _booking]);

    expect(room.coursesFor(_selection), [_booking]);
    expect(room.coursesFor({4}), [_booking]);
    expect(room.coursesFor({7}), [_booking]);
    expect(room.coursesFor({8}), isEmpty);
  });
}
