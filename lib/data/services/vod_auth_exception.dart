class VodAuthException implements Exception {
  const VodAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Campus authentication is the sole interactive login for recordings.
class VodCampusAuthRequiredException extends VodAuthException {
  const VodCampusAuthRequiredException({this.ssoExpired = false})
      : super(ssoExpired ? '校园账户登录已失效，请重新登录' : '请先登录校园账户');

  final bool ssoExpired;
}
