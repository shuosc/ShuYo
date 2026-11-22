import 'app_tab.dart';

enum CampusSystem {
  undergraduate('本科生系统', AppTab.values),
  graduate('研究生系统', [AppTab.home, AppTab.schedule]);

  const CampusSystem(this.label, this.tabs);

  final String label;
  final List<AppTab> tabs;

  AppTab supportedTab(AppTab tab) => tabs.contains(tab) ? tab : AppTab.home;
}
