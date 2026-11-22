import 'app_tab.dart';

enum CampusSystem {
  undergraduate('本科生系统', AppTab.values, identitySource: 'jwxt'),
  graduate('研究生系统', [AppTab.home, AppTab.schedule], identitySource: 'yjs');

  const CampusSystem(this.label, this.tabs, {required this.identitySource});

  final String label;
  final List<AppTab> tabs;
  final String identitySource;

  AppTab supportedTab(AppTab tab) => tabs.contains(tab) ? tab : AppTab.home;
}
