import 'common.dart';

/// The student details displayed on the academic page.
class AcademicStudentProfile {
  const AcademicStudentProfile({
    required this.studentId,
    required this.studentName,
    required this.grade,
    required this.collegeName,
    required this.majorName,
    this.academicLevel = '',
  });

  final String studentId;
  final String studentName;
  final String grade;
  final String collegeName;
  final String majorName;

  /// The education level as reported by the student-status API (`ccmc`).
  final String academicLevel;

  /// A display label only for recognized education levels.
  String get studentCategory => switch (academicLevel.trim()) {
        '本科' || '本科生' => '本科生',
        '研究生' || '硕士' || '博士' || '硕士研究生' || '博士研究生' => '研究生',
        _ => '',
      };

  JsonMap toJson() => {
        'studentId': studentId,
        'studentName': studentName,
        'grade': grade,
        'collegeName': collegeName,
        'majorName': majorName,
        'academicLevel': academicLevel,
      };

  factory AcademicStudentProfile.fromJson(JsonMap json) =>
      AcademicStudentProfile(
        studentId: stringValue(json['studentId']),
        studentName: stringValue(json['studentName']),
        grade: stringValue(json['grade']),
        collegeName: stringValue(json['collegeName']),
        majorName: stringValue(json['majorName']),
        academicLevel: stringValue(json['academicLevel']),
      );
}
