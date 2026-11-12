# ShuYo

[![Website](https://img.shields.io/badge/website-shuyo.work-1677ff)](https://shuyo.work)

专为SHUer设计的校园一站式服务APP！

- 课表查询与同步、上课提醒
- 学业修读情况查询与同步
- 空教室查询
- 通知公告

## 安装

### Android
Android 版本可以打开 [release 页面](https://github.com/shuosc/ShuYo/releases) 或通过 [ShuYo网站](https://download.shuyo.work/latest.apk) 下载。（依据设备差异，您可能需要在设置中允许「安装来自未知来源的应用」）

### iOS/iPadOS
当前暂未上架App Store，我们正在努力推进ShuYo上架国区App Store。

如果您遇到了本应用中不符合预期的行为，欢迎先查看已有的 [Issues](https://github.com/shuosc/ShuYo/issues)，也可以[新建 Issue](https://github.com/shuosc/ShuYo/issues/new/choose) 反馈问题或提出建议。修复问题或新增功能时，欢迎提交 Pull Request。

## 编译说明

本应用使用 [Dart](https://dart.dev/) 和 [Flutter](https://flutter.dev/) 开发。

本地开发、CI 和发布流程统一使用 Flutter **3.50.0（stable）**。升级 SDK 时，请同步更新工作流中的版本配置。

```text
Flutter 3.50.0 • channel stable
Dart 3.14.0 • DevTools 2.61.0
```

为了构建本应用，您需要[下载](https://flutter.cn/docs/get-started/install)并安装 `Flutter SDK`，将 `flutter` 加入 PATH；

如果您正在为 `Android` 平台构建，需要安装 [Android Studio](https://developer.android.google.cn/studio)、配置 Android SDK 与 [Android Command Line Tools](https://developer.android.google.cn/studio)，并准备好可用的 Android 模拟器或真机设备。

如果您正在为 `iOS/iPadOS` 平台构建，您还需要[安装并配置](https://apps.apple.com/app/id497799835) `Xcode`，并准备可用的 Simulator 或真机进行调试。

确定配置正确后，在项目根目录执行：

```shell
flutter pub get
flutter devices
flutter run -d <device-id>
```

运行测试：

```shell
flutter test
```

开发约定：[LLM 使用政策](LLM_POLICY.md)
