import 'academic_schedule_api_client.dart';

/// Retries an expired academic request once after restoring its business session.
///
/// A declined/unavailable recovery returns null. Errors from the retry propagate
/// without triggering another recovery, and non-authentication errors are left
/// to the caller.
Future<T?> requestWithAcademicSessionRecovery<T>({
  required Future<T> Function() request,
  required Future<bool> Function() recoverSession,
}) async {
  try {
    return await request();
  } on AcademicAuthException {
    if (!await recoverSession()) return null;
    return request();
  }
}
