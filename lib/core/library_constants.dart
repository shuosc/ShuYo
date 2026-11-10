class LibraryConstants {
  const LibraryConstants._();

  /// 超星图书馆 SaaS 平台机构代码（上海大学租户代码）
  static const groupCode = '201578';

  /// 统一检索与馆藏主站 Host
  static const host = 'findshu.libsp.cn';
  static const baseUrl = 'https://$host';

  /// 认证重定向所涉及的合法主机
  static const newssoHost = 'newsso.shu.edu.cn';
  static const chaoxingAuthHost = 'tyrzfw.chaoxing.com';

  /// OAuth 凭据参数
  static const oauthClientId = 'sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37';
  static const oauthRedirectUri =
      'https://tyrzfw.chaoxing.com/OAuth2/shu/index';

  static Uri get authorizeUri => Uri.parse(
        'https://$newssoHost/oauth/authorize'
        '?response_type=code'
        '&redirect_uri=${Uri.encodeComponent(oauthRedirectUri)}'
        '&client_id=$oauthClientId',
      );

  /// 允许的重定向 Host 集合
  static const allowedRedirectHosts = {
    newssoHost,
    'oauth.shu.edu.cn',
    chaoxingAuthHost,
    host,
  };
}
