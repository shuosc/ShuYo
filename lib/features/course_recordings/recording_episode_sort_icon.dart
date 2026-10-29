import 'package:flutter/material.dart';

class RecordingEpisodeSortIcon extends StatelessWidget {
  const RecordingEpisodeSortIcon({super.key, required this.descending});

  final bool descending;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 22,
        height: 22,
        child: MediaQuery.withNoTextScaling(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              width: 8,
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(descending ? '9' : '0',
                        style: TextStyle(
                            fontSize: 9,
                            height: 1,
                            color: IconTheme.of(context).color,
                            fontWeight: FontWeight.bold)),
                    Text(descending ? '0' : '9',
                        style: TextStyle(
                            fontSize: 9,
                            height: 1,
                            color: IconTheme.of(context).color,
                            fontWeight: FontWeight.bold)),
                  ]),
            ),
            const Icon(Icons.arrow_downward, size: 14),
          ]),
        ),
      );
}
