# 发布检查清单

## RC 之前

- `xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `swift test --package-path TypeWhisperPluginSDK`
- `xcodebuild -project TypeWhisper.xcodeproj -scheme TypeWhisper -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_first_party_warnings.sh build.log`
- 审查 README、安全政策和支持矩阵

## RC 冒烟检查

- 在 `release-candidate` 频道发布 `1.0.0-rc*`，在 `daily` 频道发布每日构建
- 稳定版构建必须仅使用默认频道
- 全新安装
- 权限恢复
- 首次听写
- 文件转录
- 提示词动作
- 历史编辑/导出
- Profile 匹配
- 插件启用/禁用
- 本地验证 CLI 和 HTTP API
- 从 `0.14.x` 升级

## `1.0.0` 之前

- 在真实机器上观察 `1.0.0-rc1` 多日
- 核心工作流无开放 P0/P1 bug
- 更新发布说明
- RC 和 daily 标签不得更新 Homebrew
- 验证 DMG、appcast 和 Homebrew 更新仅在最终 `1.0.0` 时发生
