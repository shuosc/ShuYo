import 'package:flutter/material.dart';

import '../theme/course_color.dart';

class CourseColorLabel extends StatelessWidget {
  const CourseColorLabel({
    super.key,
    required this.code,
    required this.name,
    required this.child,
  });

  final String code;
  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final seed = code.trim().isNotEmpty ? code.trim() : name.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 8),
          child: Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: courseColorForSeed(context, seed),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
