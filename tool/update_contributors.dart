import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:shuyo/data/models/github_contributor.dart';
import 'package:shuyo/data/models/github_contributors_snapshot.dart';
import 'src/github_contributors_client.dart';

const _defaultOutput = 'assets/contributors/contributors.json';

Future<void> main(List<String> arguments) async {
  exitCode = await runUpdateContributors(arguments);
}

/// Updating uses GitHub only during development/builds. Checking is fully offline.
Future<int> runUpdateContributors(
  List<String> arguments, {
  GitHubContributorsClient? client,
  http.Client? apiHttpClient,
  Map<String, String>? environment,
  Future<String?> Function()? tokenLoader,
  DateTime Function()? now,
  void Function(String)? output,
  void Function(String)? warning,
}) async {
  final void Function(String) writeOutput =
      output ?? ((message) => stdout.writeln(message));
  final void Function(String) writeWarning =
      warning ?? ((message) => stderr.writeln(message));
  var outputPath = _defaultOutput;
  var check = false;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--check') {
      check = true;
    } else if (argument == '--output' && index + 1 < arguments.length) {
      outputPath = arguments[++index];
    } else if (argument == '--help' || argument == '-h') {
      writeOutput('Usage: dart run tool/update_contributors.dart [--check] '
          '[--output <snapshot.json>]');
      return 0;
    } else {
      writeWarning('Invalid arguments. Use --help for usage.');
      return 1;
    }
  }
  final snapshotFile = File(outputPath).absolute;
  final previous = await _readSnapshot(snapshotFile);
  if (check) {
    if (previous == null || !_complete(previous.contributors)) {
      writeWarning('Contributor snapshot is missing, invalid or incomplete.');
      return 1;
    }
    writeOutput('Contributor snapshot valid: ${previous.contributors.length} '
        'contributors, generated ${previous.generatedAt.toUtc().toIso8601String()}.');
    return 0;
  }

  final hasFallback = previous != null && _complete(previous.contributors);
  final ownsClient = client == null;
  GitHubContributorsClient? github = client;
  try {
    if (github == null) {
      final token = await _readToken(
        environment ?? Platform.environment,
        tokenLoader ?? _readGhToken,
      );
      github =
          GitHubContributorsClient(httpClient: apiHttpClient, token: token);
    }
    final contributors = await github.fetchContributors(
      previous: previous?.contributors ?? const [],
    );
    if (!_complete(contributors)) {
      throw const GitHubContributorsClientException(
        'GitHub has not supplied complete contributor statistics.',
      );
    }
    final snapshot = GitHubContributorsSnapshot(
      generatedAt: (now ?? DateTime.now)().toUtc(),
      contributors: contributors,
    );
    final verified = GitHubContributorsSnapshot.fromJson(snapshot.toJson());
    await _atomicWrite(
      snapshotFile,
      utf8.encode(
          '${const JsonEncoder.withIndent('  ').convert(verified.toJson())}\n'),
    );
    writeOutput(
        'Updated contributor snapshot: ${contributors.length} contributors.');
    return 0;
  } on Object {
    // Never echo an HTTP/process exception: it can contain authorization data.
    if (hasFallback) {
      writeWarning('Warning: contributor update failed; keeping the existing '
          'complete snapshot.');
      return 0;
    }
    writeWarning('Contributor update failed and no complete local snapshot is '
        'available. Check network/GitHub statistics and retry. '
        'GH_TOKEN, GITHUB_TOKEN or an existing gh login can authenticate requests.');
    return 1;
  } finally {
    if (ownsClient) github?.close();
  }
}

Future<String?> _readToken(
  Map<String, String> environment,
  Future<String?> Function() tokenLoader,
) async {
  for (final key in ['GH_TOKEN', 'GITHUB_TOKEN']) {
    final token = environment[key]?.trim();
    if (token != null && token.isNotEmpty) return token;
  }
  try {
    final token = (await tokenLoader())?.trim();
    return token == null || token.isEmpty ? null : token;
  } on Object {
    return null;
  }
}

Future<String?> _readGhToken() async {
  Process? process;
  try {
    process = await Process.start(
      'gh',
      ['auth', 'token', '--hostname', 'github.com'],
      runInShell: Platform.isWindows,
    );
    final tokenFuture = process.stdout.transform(utf8.decoder).join();
    final drainErrors = process.stderr.drain<void>();
    final code = await process.exitCode.timeout(const Duration(seconds: 5));
    final token = await tokenFuture;
    await drainErrors;
    return code == 0 ? token.trim() : null;
  } on Object {
    process?.kill();
    return null;
  }
}

Future<GitHubContributorsSnapshot?> _readSnapshot(File file) async {
  try {
    return GitHubContributorsSnapshot.fromJson(
      jsonDecode(await file.readAsString()),
    );
  } on Object {
    return null;
  }
}

bool _complete(List<GitHubContributor> contributors) =>
    contributors.isNotEmpty &&
    contributors.every((contributor) =>
        contributor.additions != null && contributor.deletions != null);

Future<void> _atomicWrite(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temporary = File('${target.path}.tmp-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
