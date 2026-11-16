import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/data/services/vod_recording_cache.dart';
import 'package:shuyo/data/services/vod_recording_storage.dart';

/// Repository tests exercise the production encryption and worker on a private
/// temporary disk, without depending on Android/iOS platform plugins.
void useRecordingStorageFixture() {
  late Directory directory;
  late VodRecordingStorage storage;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shuyo-vod-repository-');
    storage = await VodRecordingStorage.open(
        directory: directory.path, encryptionKey: List.generate(32, (i) => i));
    VodRecordingCache.storageFactory = () async => storage;
  });
  tearDown(() async {
    await VodRecordingCache.flush();
    VodRecordingCache.storageFactory = null;
    await storage.close();
    await directory.delete(recursive: true);
  });
}
