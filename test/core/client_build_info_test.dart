import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuyo/core/client_build_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const hash = 'f98d927e1f26da1592a9361c83942596648453a2';

  test('links to the full compiled revision and displays its short hash', () {
    final revision = ClientBuildRevision(
      branch: ' feat/about-page ',
      commitHash: ' ${hash.toUpperCase()} ',
    );

    expect(revision.branch, 'feat/about-page');
    expect(revision.shortCommitHash, 'f98d927');
    expect(revision.displayLabel, 'feat/about-page · f98d927');
    expect(revision.commitUrl.toString(),
        'https://github.com/shuosc/ShuYo/commit/$hash');
  });

  test('missing or malformed metadata never produces a commit link', () {
    for (final commit in ['', 'f98d927', '../main', 'g' * 40]) {
      final revision = ClientBuildRevision(branch: '', commitHash: commit);
      expect(revision.hasCommit, isFalse);
      expect(revision.commitUrl, isNull);
      expect(revision.shortCommitHash, isEmpty);
      expect(revision.displayLabel, '版本信息不可用');
    }
  });

  test('a detached checkout keeps its compiled commit', () {
    final revision = ClientBuildRevision(branch: '', commitHash: hash);

    expect(revision.displayLabel, 'detached HEAD · f98d927');
    expect(revision.hasCommit, isTrue);
  });

  test('loads the installed native build metadata only once', () async {
    const channel = MethodChannel('work.shuyo.app/build_info');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getBuildInfo');
      calls++;
      return {'branch': 'main', 'commitHash': hash};
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await Future.wait([ClientBuildInfo.load(), ClientBuildInfo.load()]);

    expect(calls, 1);
    expect(ClientBuildInfo.branch, 'main');
    expect(ClientBuildInfo.commitHash, hash);
    expect(ClientBuildInfo.displayLabel, 'main · f98d927');
    expect(ClientBuildInfo.commitUrl.toString(),
        'https://github.com/shuosc/ShuYo/commit/$hash');
  });
}
