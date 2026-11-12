# 参与 ShuYo 贡献

感谢你愿意为 ShuYo 做出贡献！我们欢迎认真提交的 Bug 报告、功能建议、文档改进和代码贡献。

我们希望贡献流程保持友好、简单。即使这是你第一次参与 Flutter 项目，也不必担心；请描述你尝试过的内容，我们会尽力提供帮助。

## 开始之前

- 创建新 Issue 前，请先搜索已有的 [Issues](https://github.com/shuosc/ShuYo/issues) 和 Pull Request，避免重复提交。
- 报告 Bug 或提出功能想法时，请使用合适的 [Issue 模板](https://github.com/shuosc/ShuYo/issues/new/choose)。
- 对于较大的改动，可以先创建 Issue 讨论方案，再开始编写代码。
- 请勿在 Issue、Pull Request、截图、日志或测试数据中包含密码、Cookie、Token、API Key、私钥或真实个人信息。

## 开发环境

ShuYo 使用 Dart 和 Flutter 开发，当前统一使用 **Flutter 3.50.0（stable）**。请参考 [README](README.md) 中的环境配置说明，安装对应版本，并确认本地 SDK 与 CI、发布流程一致：

```shell
flutter --version
```

然后在项目根目录执行：

```shell
flutter pub get
flutter devices
flutter run -d <device-id>
```

Android 开发需要 Android Studio 和已配置的 Android SDK。iOS 开发需要 Xcode，以及可用的 Simulator 或真机设备。

## 项目方向与功能建议

ShuYo 的核心功能目前已基本完善。后续工作主要集中在现有功能的交互体验、稳定性、兼容性和维护性改进，以及 Bug 修复。

如果你有新的功能想法，请先创建 [Issue](https://github.com/shuosc/ShuYo/issues)，说明使用场景、要解决的问题和预期方案，等待维护者与社区充分讨论后再决定是否加入。未经讨论和确认的新功能 Pull Request 可能不会被采纳，因此建议先沟通方案，以免投入时间编写的代码最终无法合并。

我们尤其欢迎以下贡献：

- 报告能够稳定复现的 Bug，并协助验证修复结果；
- 修复已确认的 Bug；
- 改善现有功能的交互和可用性；
- 补充测试、文档和跨平台兼容性改进。

## 开发流程

1. 从 `main` 创建一个专注于单项任务的分支。
2. 以解决问题所需的最小改动为目标。
3. 保持生产代码、测试和文档与改动内容一致。
4. 创建 Pull Request 前，格式化并验证代码：

   ```shell
   dart format .
   flutter analyze
   flutter test
   ```

5. 如果改动涉及 iOS、Android、通知、小组件、WebView、登录或网络功能，请在受影响的平台上使用 Simulator 或真机测试，并在 Pull Request 中说明结果。
6. 使用仓库的 [Pull Request 模板](.github/pull_request_template.md) 创建 PR，说明改动内容、关联的 Issue、受影响的平台以及已经执行的检查。

`Flutter CI` 工作流会对推送到 `main` 的提交，以及目标分支为 `main` 的 Pull Request，运行 `flutter analyze` 和 `flutter test`。

## 代码风格

- 遵循现有的 Dart 和 Flutter 代码习惯，并使用 `dart format` 格式化代码。
- 使用清晰的名称，保持方法和类的职责单一。
- 避免重复代码和不必要的依赖。
- 将平台特定的改动保持在适当范围内，并为不明显的设计决策补充说明。
- 行为发生变化时，添加或更新相应的测试。

## 提交信息

请使用简短且能够说明内容的提交标题，格式如下：

```text
<type>: <description>
```

常用的类型包括：

- `feat`：新增功能；
- `fix`：修复 Bug；
- `docs`：更新文档；
- `refactor`：在不改变行为的情况下调整代码结构；
- `test`：添加或更新测试；
- `chore`：维护构建工具或仓库配置；
- `style`：进行格式化或其他不影响功能的代码风格调整。

例如：

```text
docs: add contribution guidelines
```

## 其他项目规范

- 请遵守 [ShuYo 社区行为准则](CODE_OF_CONDUCT.md)。
- 如果在开发过程中使用了 LLM，请遵守 [LLM 使用政策](LLM_POLICY.md)。

再次感谢你帮助 ShuYo 变得更好！
