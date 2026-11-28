# ShuYo 测试说明

## 本地运行

在项目根目录执行 `flutter test` 运行全部测试。如需仅运行与改动相关的用例，可以指定测试文件或目录，例如：

```shell
# 首页登录入口与页面展示
flutter test test/features/home/home_dashboard_page_test.dart

# 课表更新确认、取消和会话恢复
flutter test test/features/home/academic_schedule_menu_actions_test.dart test/app/academic_schedule_session_recovery_test.dart

# 图书馆预约模块
flutter test test/features/library_booking

# 图书馆预约流程
flutter test test/features/library_booking/library_booking_flow_test.dart
```

提交 Pull Request 前的检查和平台验证要求见[贡献指南](../CONTRIBUTING.md#开发流程)。

## 测试编写规范

- Widget 测试应验证操作结果，例如页面跳转、请求发送或数据保存。定位按钮、菜单项等控件时，优先使用已有的稳定 `ValueKey`。
- 文本断言用于检查界面是否显示必要信息。例如，课表更新提示应说明本地编辑不会保留，删除提示应列出将被清除的数据类型，预约页面应显示用户选中的日期和座位。仅在有固定措辞要求时匹配完整文案。
- 自动化测试不使用真实账号或线上接口。依赖当前时间的用例使用固定时钟，例如在预约测试中通过 `schoolClock` 指定时间。验证异步状态时，使用测试替身控制请求或存储操作的完成时机，不用固定延时等待结果。
- 页面测试验证界面交互及传给客户端的参数，客户端测试验证请求格式和响应处理。例如，预约页面测试检查所选日期是否传给客户端，客户端测试检查该日期是否按接口要求写入请求。
