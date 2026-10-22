# Glint Architecture v0.1

- 状态：现行草案
- 日期：2026-10-19
- 最近校准：2026-10-22
- 平台：macOS 14+，Apple Silicon
- 语言：Swift 6
- 关联 PRD：`docs/PRD-v0.2.md`
- 关联 Demo：外部 PinyinLensDemo 原型仓库

## 1. 架构目标

Glint 是一个菜单栏工具 + 主窗口 + 单行 HUD 的 macOS App。架构优先保证：

1. 原生 macOS 集成：Accessibility、TIS、AppKit；候选识别不截图、不执行 OCR。
2. 全局默认生效，但只读取当前输入法候选，不读文本正文。
3. CC-CEDICT、ECDICT、Wiktionary 和 OPUS-MT 是只读内置核心能力；其他词典与
   更大的翻译模型按插件管理。OPUS-MT 在构建时从固定 Hugging Face revision
   转换为 CTranslate2 int8，校验产物后进入 App bundle，不存入 Git 历史。
4. 翻译运行时可以替换，但插件不执行任意第三方代码。
5. App 逻辑与模型实验分离，先完成 M1 模型 spike，再把胜出的运行时接进 App。
6. 默认不保存候选文本、翻译结果或输入历史。

## 2. 技术栈

| 层 | 选型 |
|---|---|
| 语言 | Swift 6 |
| App 生命周期 | AppKit `NSApplicationDelegate` |
| 主窗口 | AppKit `NSWindow` + SwiftUI `NSHostingController` |
| HUD | AppKit `NSPanel` + SwiftUI `NSHostingView` |
| UI | 系统 AppKit/SwiftUI 控件，不引入第三方 UI 组件库 |
| 候选读取 | Accessibility `InputMethodCandidateList` |
| 上下文 | 当前不读取输入框正文；如后续启用，必须单独评审隐私边界 |
| 输入状态 | Carbon TIS + Accessibility API |
| 词典 | 系统 SQLite3，CC-CEDICT，ECDICT 作为反查/词频辅助 |
| 轻量翻译 | CTranslate2 int8（OPUS-MT） |
| 专用翻译 LLM | MLX Swift（Hy-MT2 1.8B / Index-Translate 2B） |
| 通用多语言 LLM | MLX Swift（Qwen3 0.6B / 1.7B / 4B，可选） |
| 插件管理 | 自研 manifest + 下载/校验/安装器 |
| 更新 | 尚未接入 |
| 日志 | OSLog，默认脱敏 |
| 分发 | Developer ID + 公证，先直接下载 |

## 3. 目录结构

```text
Glint/
├── README.md
├── Glint.xcworkspace
├── App/
│   ├── Glint/
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppEnvironment.swift
│   │   ├── Info.plist
│   │   ├── Glint.entitlements
│   │   └── Assets.xcassets
│   └── GlintTests/
├── Packages/
│   ├── GlintCore/
│   │   ├── Package.swift
│   │   ├── Sources/GlintCore/
│   │   │   ├── Domain/
│   │   │   ├── Contracts/
│   │   │   └── Routing/
│   │   └── Tests/GlintCoreTests/
│   ├── GlintMac/
│   │   ├── Package.swift
│   │   ├── Sources/GlintMac/
│   │   │   ├── Accessibility/
│   │   │   └── InputSource/
│   │   └── Tests/GlintMacTests/
│   ├── GlintDictionary/
│   │   ├── Package.swift
│   │   ├── Sources/GlintDictionary/
│   │   │   ├── SQLite/
│   │   │   ├── Lookup/
│   │   │   └── Ranking/
│   │   └── Tests/GlintDictionaryTests/
│   ├── GlintInference/
│   │   ├── Package.swift
│   │   ├── Sources/GlintInference/
│   │   │   ├── Contracts/
│   │   │   ├── CTranslate2/
│   │   │   └── MLX/
│   │   └── Tests/GlintInferenceTests/
│   ├── GlintPlugins/
│   │   ├── Package.swift
│   │   ├── Sources/GlintPlugins/
│   │   │   ├── Manifest/
│   │   │   ├── Download/
│   │   │   └── Install/
│   │   └── Tests/GlintPluginsTests/
│   └── GlintUI/
│       ├── Package.swift
│       ├── Sources/GlintUI/
│       │   ├── MainWindow/
│       │   ├── HUD/
│       │   ├── Onboarding/
│       │   └── Components/
│       └── Tests/GlintUITests/
├── Bridges/
│   └── CTranslate2Bridge/
│       ├── Package.swift
│       └── Sources/CTranslate2Bridge/
│           ├── include/
│           └── CTranslate2Bridge.mm
├── Tools/
│   ├── GlintEval/
│   │   ├── Package.swift
│   │   └── Sources/GlintEval/
│   └── ModelLab/
│       ├── README.md
│       ├── requirements.txt
│       ├── convert/
│       ├── eval/
│       └── results/
├── Resources/
│   ├── Dictionary/
│   ├── Evaluation/
│   ├── Plugins/
│   └── catalog.json
├── docs/
│   ├── PRD-v0.2.md
│   ├── ARCHITECTURE-v0.1.md
│   └── ADR/
├── scripts/
│   ├── build.sh
│   ├── test.sh
│   ├── download_models.sh
│   └── notarize.sh
└── Tests/
    ├── Integration/
    └── Fixtures/
```

## 4. 模块边界

### GlintCore

纯 Swift，不依赖 AppKit 或数据库。

包含：

- `Candidate`、`CandidateKind`、`EnglishResult`、`TranslationMode`；
- `DictionaryEngine`、`TranslationEngine` 协议；
- `SmartRouter`：词典/模型/不显示的路由；
- `AppPolicy`：MVP 固定 `.all`，后续白名单/黑名单；
- 公共错误类型和插件 manifest 的领域模型。

### GlintMac

所有 macOS 平台相关实现：

- TIS 输入源判断；
- Accessibility 光标/控件 frame；
- Accessibility 输入法候选读取；
- 安全输入判断；
- 当前不读取输入框正文；如后续启用上下文，必须经过独立隐私评审。

不包含 UI、插件下载或词典数据。

### GlintDictionary

- SQLite3 数据库访问；
- CC-CEDICT 词条查询；
- 英文对应词排序（词频、ECDICT 反查、人工 override）；
- 词典插件的加载接口。

不依赖 AppKit。

### GlintInference

- `TranslationEngine` 的实现；
- CTranslate2 适配器；
- MLX 适配器；
- 模型加载、内存预算、推理取消；
- 不负责下载，不负责 UI。

### GlintPlugins

- manifest 解析和版本校验；
- 下载、SHA256 校验、解压、原子安装；
- 插件目录管理、删除、更新；
- `PluginManager` actor；
- 不执行插件代码，模型只作为数据加载。

### GlintUI

- `MainWindowController` + SwiftUI 页面；
- `HUDController` + `NSPanel`；
- 侧栏、插件卡片、权限卡片、预览；
- 依赖 `GlintCore` 的领域类型和 `GlintPlugins` 的 manifest/manager
  接口，不直接实现截取或推理。

### GlintApp

组合根，只做：

- App 生命周期；
- 创建 `AppEnvironment`；
- 注入具体实现；
- 菜单栏、主窗口、HUD 的协调；
- 权限引导和启动/停止监控。

### Tools/ModelLab

Python 实验环境，只用于 M1：

- 模型下载和转换；
- 50 条测试集；
- 质量、延迟、内存评测；
- 生成 `docs/M1-MODEL-SPIKE.md`。

不进入 App 安装包。

## 5. 依赖规则

```text
GlintApp
  → GlintUI / GlintMac / GlintDictionary / GlintInference / GlintPlugins

GlintUI
  → GlintCore / GlintPlugins

GlintMac / GlintDictionary / GlintInference / GlintPlugins
  → GlintCore

GlintCore
  → 无 AppKit / SQLite / MLX 依赖
```

规则：

- 不允许反向依赖：`GlintCore` 不能 import 上面任何模块。
- `GlintMac` 不能 import `GlintUI`。
- `GlintInference` 不能 import `GlintPlugins`；模型路径由 App/PluginManager 注入。
- `GlintUI` 不直接持有 `CTranslate2`/`MLX` 类型，只通过 `TranslationEngine` 协议。
- `Bridges/CTranslate2Bridge` 只被 `GlintInference` 依赖。

## 6. App 生命周期与 UI

- AppKit `NSApplicationDelegate`，`LSUIElement = true`，只驻留菜单栏。
- 首次启动打开 `MainWindow`；关闭窗口只隐藏，不退出监控。
- `MainWindow` 是独立 `NSWindow`，内容由 SwiftUI `NavigationSplitView` 承载。
- `HUDController` 管理非激活 `NSPanel`：
  - borderless；
  - `.nonactivatingPanel`；
  - popUpMenu level；
  - `canJoinAllSpaces` + `fullScreenAuxiliary`；
  - 不抢焦点，不改变候选选择。
- 主窗口和 HUD 都通过 `AppEnvironment` 获取状态，不直接互相调用。

## 7. 运行时数据流

```text
InputSourceMonitor (TIS)
  → FocusMonitor (AX)
  → AXCandidateReader (selected candidate title + frame)
  → SmartRouter (GlintCore)
      ├─ DictionaryEngine (GlintDictionary)
      └─ TranslationEngine (GlintInference)
  → HUDController (AppKit + SwiftUI)
```

主窗口只是观察同一套状态：

```text
MonitoringController → @Observable AppState → MainWindowView
```

## 8. 并发与状态

- `MonitoringController`：主线程上的轻量调度器；定时/事件触发，单飞（single-flight）。
- `AXCandidateReader`：候选识别主路径，缓存应用与候选列表节点。
- `AXCandidateReader`：候选识别唯一主路径。
- `TranslationPipeline`：actor，取消旧请求，避免旧结果覆盖新候选。
- `PluginManager`/`ModelDownloader`：actor；下载状态通过 AsyncStream 发布。
- UI：`@MainActor`；只接收不可变的展示状态。
- 缓存：内存 LRU；不落盘；候选变化时取消旧请求。

## 9. 插件与模型

- 插件 manifest 是唯一入口；模型/词库是数据，不带可执行代码。
- 支持两种插件类型：`dictionary`、`translation`。
- 固定运行时适配器：
  - `cedict-sqlite` → CC-CEDICT 查询与 overrides；
  - `ecdict-rank` → ECDICT 词频和义项排序；
  - `sqlite-v1` → 扩展词典；
  - `ctranslate2` → CTranslate2Bridge；
  - `mlx` → MLX Swift；
  - `apple-translation` → 可选的系统适配器。
- CC-CEDICT、overrides、ECDICT、Wiktionary 和 OPUS-MT 作为只读核心资源直接
  随 App 提供，不复制到 Application Support，不参与安装和卸载。OPUS-MT 由
  `scripts/prepare_opus_model.sh` 在构建前转换并校验，锁文件记录源 revision、
  工具版本和每个产物的 SHA256。
- 词典路由由只读内置词典和 Application Support 中的可选插件合并；内置 ID
  优先，插件列表不得重复注册同一词典。
- 下载目录：

```text
~/Library/Application Support/Glint/
  plugins/
    mt-hy-mt2-1.8b/
  models/
  cache/
  logs/
```

- 安装流程：下载可选插件 → 校验 manifest 和 SHA256 → 原子替换插件目录 →
  更新 registry。
- 删除流程：先取消推理/卸载模型，再删除目录和 registry 条目。核心词典和
  内置 OPUS-MT 不提供删除操作。
- 不支持任意第三方 dylib、脚本或可执行文件。

## 10. 持久化与隐私

- 词典：只读 SQLite；模型：文件目录；设置：UserDefaults/JSON。
- 不保存候选文本、翻译结果、输入历史、剪贴板、窗口标题。
- 运行日志用 OSLog，候选文本/翻译内容默认 `.private`，不写文件。
- 安全输入场景直接跳过。
- 推理阶段不联网；只有用户主动下载/更新插件时使用 URLSession。

## 11. 构建与依赖

- Xcode workspace + 本地 Swift packages + 一个 App target。
- 依赖：
  - 系统 SQLite3；
  - MLX Swift（高质量翻译插件）；
  - CTranslate2（通过 `Bridges/CTranslate2Bridge`）。
- App target 只复制运行时 allowlist：`catalog.json`、`dict-cedict`、
  `dict-ecdict`、`dict-wiktionary-zh-en` 和 `mt-opus-zh-en` 五个只读核心
  资源。OPUS-MT 权重由构建脚本准备且不进入 Git；评测数据、可选插件和其他
  模型目录不得由 `Resources` 整目录进入 App。
- App 第一版不启用 App Sandbox；使用 Developer ID + hardened runtime + 公证。
- Bundle ID 暂定 `com.local.glint`，正式签名/团队确定后再改。
- `scripts/build.sh`、`scripts/test.sh` 只封装 `xcodebuild`/`swift test`，不复制 demo 的 `swiftc` 流程。

## 12. 测试

### 单元测试

- `SmartRouter` 的路由/歧义/无结果；
- 候选文本清洗、数字/emoji 过滤；
- 词典英文对应词排序；
- manifest 校验、版本比较、安装状态机；
- 翻译取消和缓存。

### 集成测试

- 用 AX 候选快照和 frame 数据测试 MonitoringController；
- 用 mock `TranslationEngine` 测试 HUD 显示/隐藏；
- 主窗口侧栏、插件下载状态、权限提示的 UI 测试。

### M1 模型评测

- `Tools/ModelLab` 生成 50 条测试集；
- 对比 OPUS-MT、M2M100、Qwen3-4B；
- 记录：英文对应准确率、短句自然度、p95 延迟、峰值内存、模型体积；
- 结果写入 `docs/M1-MODEL-SPIKE.md`；
- 通过后再把胜出的运行时接入 `GlintInference`。

## 13. ADR 列表

- ADR-0001：不替换输入法，采用候选栏读取 + HUD；输入候选由 AX 读取。
- ADR-0002：Swift 6 + AppKit/SwiftUI 混合。
- ADR-0003：插件模型作为数据，固定 runtime adapter。
- ADR-0004：AppKit 生命周期承载菜单栏 + 主窗口 + HUD。
- ADR-0005：先做 ModelLab，再做 App 推理集成。
- ADR-0006：不持久化候选文本和翻译结果。

## 14. 待确认

1. Xcode 工程用手写 `.xcodeproj`，还是用 XcodeGen 的 `project.yml` 生成？
2. CTranslate2 第一版是否直接 in-process 链接，还是先做独立 XPC 推理服务？
3. 模型下载托管用 GitHub Releases、自建 CDN，还是模型平台直链？
4. 主窗口是否需要在第一版支持多语言 UI（中文/英文）？
