import 'dart:async';
import 'dart:io';

import '../../core/forum_constants.dart';
import '../../core/certificate_policy.dart';
import 'http_timeout.dart';

enum ForumReachabilityStatus {
  reachable,
  unreachable,
  unknown,
}

class ForumReachabilityResult {
  const ForumReachabilityResult({
    required this.status,
    this.error,
  });

  final ForumReachabilityStatus status;
  final Object? error;

  bool get isUnavailable => status == ForumReachabilityStatus.unreachable;
}

class ForumReachabilityService {
  const ForumReachabilityService({
    this.timeout = HttpTimeout.probe,
  });

  final Duration timeout;

  Future<ForumReachabilityResult> checkDirectBbsReachability() async {
    final client = HttpClient()..connectionTimeout = timeout;
    if (CertificatePolicy.supportsForumException) {
      client.badCertificateCallback = (certificate, host, port) {
        return CertificatePolicy.allowsHost(host);
      };
    }
    try {
      await _probe(client).timeout(timeout);
      return const ForumReachabilityResult(
        status: ForumReachabilityStatus.reachable,
      );
    } on TimeoutException catch (error) {
      return ForumReachabilityResult(
        status: ForumReachabilityStatus.unreachable,
        error: error,
      );
    } on SocketException catch (error) {
      return ForumReachabilityResult(
        status: ForumReachabilityStatus.unreachable,
        error: error,
      );
    } on HandshakeException catch (error) {
      return ForumReachabilityResult(
        status: ForumReachabilityStatus.reachable,
        error: error,
      );
    } on Object catch (error) {
      return ForumReachabilityResult(
        status: ForumReachabilityStatus.unknown,
        error: error,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _probe(HttpClient client) async {
    final request = await client.getUrl(Uri.parse(ForumConstants.baseUrl));
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
  }
}
