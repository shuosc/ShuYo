import '../models/otp_token.dart';
import '../services/otp_token_api_client.dart';

/// Exposes the school dynamic password to the UI.
///
/// The token is read from the server on every call, so the repository stays a
/// thin seam over [OtpTokenApiClient]; keeping it separate lets the demo build
/// supply its own rotating value without touching the page.
class OtpTokenRepository {
  OtpTokenRepository({OtpTokenApiClient? apiClient}) : _apiClient = apiClient;

  OtpTokenApiClient? _apiClient;
  OtpTokenApiClient get _client => _apiClient ??= OtpTokenApiClient();

  Future<OtpToken> fetchToken() => _client.fetchToken();

  void dispose() {
    _apiClient?.dispose();
    _apiClient = null;
  }
}
