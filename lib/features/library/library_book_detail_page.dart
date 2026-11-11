import 'package:flutter/material.dart';

class LibraryBookDetailPage extends StatelessWidget {
  const LibraryBookDetailPage({
    super.key,
    this.recordId,
    this.title,
  });

  final int? recordId;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图书详情'),
      ),
      body: const SizedBox.expand(),
    );
  }
}
