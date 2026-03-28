# TypeWhisper 插件

TypeWhisper 支持以 macOS `.bundle` 文件形式使用外部插件。将编译好的 bundle 放置于：

```
~/Library/Application Support/TypeWhisper/Plugins/
```

## 插件类型

| 协议 | 用途 | 返回值？ |
|---|---|---|
| `TypeWhisperPlugin` | 基础协议，事件观察 | 否 |
| `PostProcessorPlugin` | 转换管道中的文本 | 是（处理后的文本）|
| `LLMProviderPlugin` | 添加自定义 LLM 提供商 | 是（LLM 响应）|
| `TranscriptionEnginePlugin` | 自定义转录引擎 | 是（转录结果）|
| `ActionPlugin` | 将 LLM 输出路由到自定义动作（例如创建 Linear Issue）| 是（动作结果）|

## 事件总线

插件可以订阅事件而无需修改转录管道：

- `recordingStarted` - 录音开始
- `recordingStopped` - 录音结束（含时长）
- `transcriptionCompleted` - 转录完成（含完整载荷）
- `transcriptionFailed` - 转录错误
- `textInserted` - 文本已插入目标应用
- `actionCompleted` - 动作插件执行完成（含结果载荷）

## 创建插件

1. 在 Xcode 中新建 **macOS Bundle** target
2. 添加 `TypeWhisperPluginSDK` 作为包依赖
3. 实现 `TypeWhisperPlugin`（或子协议）
4. 在 `Contents/Resources/` 添加 `manifest.json`
5. 构建并将 `.bundle` 复制到 Plugins 目录

### manifest.json

```json
{
    "id": "com.yourname.plugin-id",
    "name": "My Plugin",
    "version": "1.0.0",
    "minHostVersion": "0.9.0",
    "minOSVersion": "15.0",
    "author": "Your Name",
    "principalClass": "MyPluginClassName"
}
```

### 主机服务

每个插件收到一个提供以下功能的 `HostServices` 对象：

- **Keychain**：`storeSecret(key:value:)`、`loadSecret(key:)`
- **UserDefaults**（插件作用域）：`userDefault(forKey:)`、`setUserDefault(_:forKey:)`
- **数据目录**：`pluginDataDirectory` - 持久化存储，位于 `~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/`
- **应用上下文**：`activeAppBundleId`、`activeAppName`
- **Profile**：`availableProfileNames` - 用户定义的 Profile 名称列表
- **事件总线**：`eventBus` 用于订阅事件
- **能力**：`notifyCapabilitiesChanged()` - 当插件状态改变时通知主机（例如模型加载/卸载）

## 示例

参见 `WebhookPlugin/` 获取完整的 HTTP Webhook 示例，该插件在每次转录后发送 Webhook。
