class LibraryConstants {
  const LibraryConstants._();

  /// 超星图书馆 SaaS 平台机构代码（上海大学租户代码）
  static const groupCode = '201578';

  /// 网关路由必带参数（学校短名）
  static const mappingPath = 'find';

  /// 统一检索与馆藏主站 Host
  static const host = 'findshu.libsp.cn';
  static const baseUrl = 'https://$host';

  /// 认证重定向所涉及的合法主机
  static const newssoHost = 'newsso.shu.edu.cn';
  static const chaoxingAuthHost = 'tyrzfw.chaoxing.com';

  /// 图书馆前端把登录凭据放在这个请求头里。
  static const defaultJwtHeader = 'jwtOpacAuth';

  static const oauthClientId = 'sJ7Y27sGjMwOOaGPJJZW7M7JZ3777O37';

  static const chaoxingInitPath = '/OAuth2/shu/init';
  static const chaoxingCallbackPath = '/OAuth2/shu/index';
  static const chaoxingLoginPath = '/OAuth2/shu/login';
  static const ssoLoginReturnPath = '/find/sso/login/shu/0';
  static const ssoLoginReturnPrefix = '/find/sso/login/';

  /// 用户身份端点（返回姓名、院系等真实用户信息）
  static const ogaUserInfoPath = '/oga/userinfo';
  static const userInfoPath = ogaUserInfoPath;

  /// 前端校验手机与邮箱绑定的次要端点（getCheckFlag）
  static const checkFlagUserInfoPath = '/find/userInfo/getUserInfo';

  /// 今日推荐端点
  static const dailyRecommendPath = '/find/subscribe/dailyRecommend';

  /// 热门借阅榜单
  static const hotLoanPath = '/find/index/getHotLoan';

  /// 热门收藏榜单
  static const topSharePath = '/find/favorites/topShare';

  /// 高分图书榜单
  static const topScorePath = '/find/findUserEvaluation/getTopScoreList';

  /// 新书速递端点
  static const newBookPath = '/find/index/getNewBook';

  /// 实体馆藏查询端点
  static const physicalGroupItemsPath = '/find/physical/groupitems';

  /// 书目详情端点
  static const searchResultDetailPath = '/find/searchResultDetail/getDetail';

  /// 读秀封面图片地址端点
  static const duxiuCoverPath = '/find/book/getDuxiuImageUrl';

  /// 统一检索端点
  static const unifySearchPath = '/find/unify/search';

  /// 批量获取物理馆藏、在架数及读秀封面端点
  static const batchBookSupplementaryPath =
      '/find/unify/getPItemAndOnShelfCountAndDuxiuImageUrl';

  /// 授权必须从超星认证站的入口开始：它会先下发 `firstReferer` 等 Cookie，
  /// 再把浏览器带到 newsso。直接请求 newsso 会让回调缺少这些状态。
  static Uri get initUri => Uri.https(chaoxingAuthHost, chaoxingInitPath, {
        'isLogout': '0',
        'refer': '$baseUrl$ssoLoginReturnPath',
      });

  /// 允许的重定向 Host 集合
  static const allowedRedirectHosts = {
    newssoHost,
    'oauth.shu.edu.cn',
    chaoxingAuthHost,
    host,
  };
}
