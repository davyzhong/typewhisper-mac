# 安全政策

## 报告安全漏洞

如果您在 TypeWhisper 中发现安全漏洞，请负责任地进行报告。

**请勿公开提交 issue。** 请通过以下方式发送安全问题：security@typewhisper.com

您也可以使用 [GitHub 私人漏洞报告功能](https://github.com/TypeWhisper/typewhisper-mac/security/advisories/new)。

我们将在 48 小时内确认收到您的报告，并争取在 7 天内为关键问题提供修复方案。

## 范围

TypeWhisper 处理敏感数据，包括：
- 麦克风音频
- API 密钥（存储在 macOS Keychain 中）
- AppleScript 自动化（浏览器 URL 检测）
- 本地 HTTP API 服务器

这些问题领域尤其值得关注。

## 安全边界

- 本地 HTTP API 仅绑定到 `127.0.0.1`。
- API 服务器默认禁用，必须在 设置 > 高级 中显式启用。
- API 密钥存储在 macOS Keychain 中，不得出现在导出的诊断信息中。
- 支持诊断信息导出为隐私安全的 JSON 报告，不包含 API 密钥、音频数据和转录历史。

## 支持的版本

| 版本 | 支持状态 |
|---------|-----------|
| 最新正式版 | 是 |
| 当前发布候选版 / 预览版 | 尽力而为 |
| 旧版本 | 否 |
