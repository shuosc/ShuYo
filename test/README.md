# ShuYo 测试说明

## 本地怎么跑

在项目根目录运行，开发中先选择受影响的测试：

```shell
# 首页登录入口和展示
flutter test test/features/home/home_dashboard_page_test.dart

# 课表更新确认、取消和会话恢复
flutter test test/features/home/academic_schedule_menu_actions_test.dart test/app/academic_schedule_session_recovery_test.dart

# 图书馆预约：跑整个模块，或选 navigation、flow、records、sync 中的一组
flutter test test/features/library_booking
flutter test test/features/library_booking/library_booking_flow_test.dart
```

提交前一般运行 `flutter analyze` 和 `flutter test`。涉及原生能力、登录或网络行为时，按[项目约定](../LLM_POLICY.md#测试要求)在受影响的平台补做模拟器或真机验证。

## 测试应保护什么

- **点控件看结果。** 优先用已有的稳定 `ValueKey` 定位菜单、按钮等控件，再断言导航、请求或保存结果。只改按钮叫法时，行为测试应继续通过。
- **保留用户必须看到的信息。** 用文本断言验证覆盖本地编辑的警告、删除的数据类型，以及用户选中的日期和座位等。普通措辞不用逐字检查。
- **让输入可重现。** 预约测试使用 `schoolClock` 注入固定的上海时间。用可控的假服务模拟请求或存储完成，不靠真实账号、线上接口或固定时长的等待来触发这些状态。
- **在合适的层测边界。** 客户端测试验证请求怎样编码；页面测试验证选中的日期有没有正确交给客户端。两层各自保留能抓到不同错误的用例。
