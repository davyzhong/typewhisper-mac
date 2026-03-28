# 为 TypeWhisper 贡献代码

感谢您对贡献代码的兴趣！

## 入门

1. Fork 仓库并克隆到本地
2. 在 Xcode 16+ 中打开 `TypeWhisper.xcodeproj`
3. 首次构建时 SPM 依赖自动解析
4. 构建并运行（Cmd+R）——应用以菜单栏图标形式显示

## 代码签名（可选）

项目使用临时签名构建，无需任何签名配置。

使用您自己的签名身份：
```
echo 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' > CodeSigning.local.xcconfig
```

## 开发环境

- 要求 macOS 15.0+
- Swift 6 严格并发模式
- Debug 构建使用独立的数据目录（`TypeWhisper-Dev`）和 Keychain 前缀，不会干扰 Release 构建

## Pull Request

1. 从 `main` 分支创建功能分支
2. 保持更改专注——每个 PR 一个功能或修复
3. 手动测试更改并运行自动化检查
4. 填写 PR 模板（Summary + Test Plan）
5. PR 以 squash 合并方式合入 `main`

推荐检查项：

```bash
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
swift test --package-path TypeWhisperPluginSDK
```

## 代码风格

- 遵循代码库中现有的模式
- MVVM 架构，使用 `ServiceContainer` 进行依赖注入
- 本地化：所有面向用户的字符串使用 `String(localized:)`
- 使用 SwiftData 进行持久化，使用 Combine 进行响应式更新

## 报告问题

使用 [issue 模板](https://github.com/TypeWhisper/typewhisper-mac/issues/new/choose) 报告 bug 和功能请求。

## 许可证

贡献代码即表示您同意您的贡献将按 GPLv3 许可。
