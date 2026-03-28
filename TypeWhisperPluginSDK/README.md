# TypeWhisper 插件 SDK

为 [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) 构建插件，添加转录引擎、LLM 提供商、后处理器和自定义动作。

## 快速开始

### 1. 创建 Xcode Bundle Target

在您的 Xcode 项目（或 TypeWhisper 项目本身）中：

1. **File > New > Target > macOS > Bundle**
2. 将 **Product Name** 设置为您的插件名称（例如 `MyPlugin`）
3. 添加 `TypeWhisperPluginSDK` 包作为依赖

### 2. 添加清单

在您的 bundle 中创建 `Contents/Resources/manifest.json`：

```json
{
  "id": "com.yourname.myplugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "minHostVersion": "0.11",
  "minOSVersion": "15.0",
  "author": "Your Name",
  "principalClass": "MyPlugin"
}
```

- `id` - 唯一的反向域名标识符
- `principalClass` - 必须与插件类上的 `@objc(ClassName)` 匹配
- `minHostVersion` - 所需的最低 TypeWhisper 版本
- `minOSVersion` - 所需的最低 macOS 版本（插件在旧系统上会被跳过）

### 3. 实现插件

```swift
import Foundation
import SwiftUI
import TypeWhisperPluginSDK

@objc(MyPlugin)
final class MyPlugin: NSObject, PostProcessorPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myplugin"
    static let pluginName = "My Plugin"

    private var host: HostServices?

    required override init() { super.init() }

    func activate(host: HostServices) {
        self.host = host
    }

    func deactivate() {
        host = nil
    }

    // PostProcessorPlugin
    var processorName: String { "My Processor" }
    var priority: Int { 500 }

    @MainActor
    func process(text: String, context: PostProcessingContext) async throws -> String {
        // 在此处转换文本
        return text.uppercased()
    }
}
```

### 4. 安装和测试

构建插件后，使用以下方式之一安装：

- **从文件安装**：设置 > 集成 > 从文件安装...（选择 `.bundle`）
- **手动**：将 `.bundle` 复制到 `~/Library/Application Support/TypeWhisper/Plugins/`
- **符号链接**（开发用）：`ln -s /path/to/DerivedData/.../MyPlugin.bundle ~/Library/Application\ Support/TypeWhisper/Plugins/`

在 设置 > 集成 中启用您的插件。

---

## 插件类型

### TranscriptionEnginePlugin

添加语音转文字引擎。接收原始音频，返回文本。

```swift
@objc(MyTranscriptionEngine)
final class MyTranscriptionEngine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.mytranscription"
    static let pluginName = "My Transcription"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var providerId: String { "my-engine" }
    var providerDisplayName: String { "My Engine" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: "default", displayName: "Default Model")]
    }
    var selectedModelId: String? { "default" }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        // audio.samples  - [Float] 16kHz 单声道 PCM
        // audio.wavData   - 预编码的 WAV 数据
        // audio.duration  - TimeInterval
        let text = "transcribed text"
        return PluginTranscriptionResult(text: text)
    }
}
```

### LLMProviderPlugin

添加用于提示词处理（文本转换、摘要等）的 LLM。

```swift
@objc(MyLLMProvider)
final class MyLLMProvider: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myllm"
    static let pluginName = "My LLM"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var providerName: String { "My LLM" }
    var isAvailable: Bool { host?.loadSecret(key: "apiKey") != nil }
    var supportedModels: [PluginModelInfo] {
        [PluginModelInfo(id: "my-model", displayName: "My Model")]
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        let apiKey = host?.loadSecret(key: "apiKey") ?? ""
        // 在此处调用您的 LLM API
        return "processed result"
    }
}
```

对于 OpenAI 兼容 API，使用内置辅助工具：

```swift
let helper = PluginOpenAIChatHelper(baseURL: "https://api.example.com")
let result = try await helper.process(
    apiKey: apiKey, model: "my-model",
    systemPrompt: systemPrompt, userText: userText
)
```

### PostProcessorPlugin

在转录后转换文本。按优先级顺序运行（数字越小越早执行）。

```swift
var processorName: String { "My Processor" }
var priority: Int { 500 }  // 内置：LLM=300、Snippets=500、Dictionary=600

@MainActor
func process(text: String, context: PostProcessingContext) async throws -> String {
    // context.appName           - 当前应用名称
    // context.bundleIdentifier  - 当前应用 Bundle ID
    // context.url               - 浏览器 URL（如可用）
    // context.language          - 检测到的语言
    return text
}
```

### ActionPlugin

对文本执行自定义动作（例如创建 Issue、发送到 API）。

```swift
@objc(MyAction)
final class MyAction: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myaction"
    static let pluginName = "My Action"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var actionName: String { "Do Something" }
    var actionId: String { "my-action" }
    var actionIcon: String { "star.fill" }  // SF Symbol 名称

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        // context.originalText - LLM 处理前的文本
        // input                - LLM 处理后的文本
        return ActionResult(
            success: true,
            message: "Done!",
            url: "https://example.com",       // 可选，使结果可点击
            icon: "checkmark.circle.fill",     // 可选 SF Symbol
            displayDuration: 3.0              // 可选，显示反馈的秒数
        )
    }
}
```

### 多用途插件

单个插件类可以同时遵循多个协议：

```swift
@objc(MyCloudPlugin)
final class MyCloudPlugin: NSObject, TranscriptionEnginePlugin, LLMProviderPlugin, @unchecked Sendable {
    // 在一个插件中实现两个协议
}
```

---

## 主机服务

插件在激活时收到一个 `HostServices` 实例：

```swift
func activate(host: HostServices) {
    self.host = host

    // 安全存储（插件作用域的 Keychain）
    try host.storeSecret(key: "apiKey", value: "sk-...")
    let key = host.loadSecret(key: "apiKey")

    // 偏好设置（插件作用域的 UserDefaults）
    host.setUserDefault("value", forKey: "myPref")
    let pref = host.userDefault(forKey: "myPref")

    // 文件存储（~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/）
    let dataDir = host.pluginDataDirectory

    // 应用上下文
    let appName = host.activeAppName
    let bundleId = host.activeAppBundleId

    // Profile 名称
    let profiles = host.availableProfileNames
}
```

---

## 事件总线

订阅应用事件：

```swift
func activate(host: HostServices) {
    host.eventBus.subscribe { event in
        switch event {
        case .transcriptionCompleted(let payload):
            print("转录完成：\(payload.finalText)")
            print("引擎：\(payload.engineUsed)")
            print("应用：\(payload.appName ?? "未知")")
        case .recordingStarted(let payload):
            print("录音开始于 \(payload.timestamp)")
        case .recordingStopped(let payload):
            print("时长：\(payload.durationSeconds)秒")
        case .textInserted(let payload):
            print("已插入：\(payload.text)")
        case .actionCompleted(let payload):
            print("动作 \(payload.actionId)：\(payload.message)")
        case .transcriptionFailed(let payload):
            print("错误：\(payload.error)")
        }
    }
}
```

---

## 设置界面

提供 SwiftUI 视图用于插件配置：

```swift
var settingsView: AnyView? {
    AnyView(MySettingsView(plugin: self))
}
```

用户点击 设置 > 集成 中的齿轮图标时，视图会以表单形式显示。

---

## 内置辅助工具

### PluginOpenAITranscriptionHelper

用于 OpenAI 兼容的 Whisper API：

```swift
let helper = PluginOpenAITranscriptionHelper(baseURL: "https://api.groq.com/openai")
let result = try await helper.transcribe(
    audio: audio, apiKey: apiKey, modelName: "whisper-large-v3",
    language: "en", translate: false, prompt: nil
)
```

### PluginOpenAIChatHelper

用于 OpenAI 兼容的聊天 API：

```swift
let helper = PluginOpenAIChatHelper(baseURL: "https://api.openai.com")
let result = try await helper.process(
    apiKey: apiKey, model: "gpt-4o",
    systemPrompt: "Fix grammar", userText: inputText
)
```

### PluginWavEncoder

将音频采样编码为 WAV：

```swift
let wavData = PluginWavEncoder.encode(samples, sampleRate: 16000)
```

---

## 清单参考

| 字段 | 必需 | 描述 |
|-------|----------|-------------|
| `id` | 是 | 唯一反向域名 ID（例如 `com.yourname.myplugin`）|
| `name` | 是 | 显示名称 |
| `version` | 是 | 语义化版本字符串（例如 `1.0.0`）|
| `minHostVersion` | 否 | 最低 TypeWhisper 版本 |
| `minOSVersion` | 否 | 最低 macOS 版本（例如 `15.0`、`26.0`）。插件在旧系统上会被跳过。|
| `author` | 否 | 作者名称 |
| `principalClass` | 是 | Objective-C 类名，必须与 `@objc(Name)` 匹配 |

---

## 发布

要通过 TypeWhisper 插件市场分发：

1. 以 Release 配置构建插件
2. 将 `.bundle` 压缩为 ZIP：`ditto -ck --sequesterRsrc MyPlugin.bundle MyPlugin.zip`
3. 托管 ZIP 文件（GitHub Releases、自有服务器等）
4. 提交 PR 将插件添加到 [插件注册表](https://github.com/TypeWhisper/typewhisper-mac/blob/gh-pages/plugins.json)

注册表条目格式：

```json
{
  "id": "com.yourname.myplugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "minHostVersion": "0.11",
  "minOSVersion": "15.0",
  "author": "Your Name",
  "description": "What your plugin does.",
  "category": "transcription|llm|postprocessor|action",
  "size": 12345678,
  "downloadURL": "https://example.com/MyPlugin.zip",
  "iconSystemName": "star.fill"
}
```

---

## 要求

- macOS 15.0+
- Swift 6.0
- TypeWhisper 0.11+
