# Glint Architecture

- 状态：现行
- 日期：2026-10-19
- 最近校准：2026-10-23
- 平台：macOS 26+，Apple Silicon
- 语言：Swift 6

## 1. 架构目标

Glint 是一个菜单栏工具 + 主窗口 + 单行 HUD 的 macOS App。架构优先保证：

1. 原生 macOS 集成：Accessibility、TIS、AppKit；候选识别不截图、不执行 OCR。
2. 全局默认生效，但只读取当前输入法候选，不读文本正文。
3. CC-CEDICT、ECDICT、Wiktionary 和 OPUS-MT 是只读内置核心能力；其他词典与
   更大的翻译模型按插件管理。OPUS-MT 在构建时从固定 Hugging Face revision
   转换为 CTranslate2 int8，校验产物后进入 App bundle，不存入 Git 历史。
4. 翻译运行时可以替换，但插件不执行任意第三方代码。
5. App 逻辑与模型实验分离；模型评测结论与生产运行时保持可追溯。
6. 默认不保存候选文本、翻译结果或输入历史。

## 2. 技术栈

| 层 | 选型 |
|---|---|
| 语言 | Swift 6 |
| App 生命周期 | AppKit `NSApplicationDelegate` |
| 主窗口 | AppKit `NSWindow` + SwiftUI `NSHostingController` |
| HUD | AppKit `NSPanel` + SwiftUI `NSHostingView` |
| UI | 系统 AppKit/SwiftUI 控件，不引入第三方 UI 组件库 |
| 候选读取 | Accessibility `InputMethodCandidateList` + 微信输入法专用 AX 样式解析 |
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
│   ├── Glint/                 # App 生命周期、组合根和命令行诊断
│   └── GlintTests/            # App target 冒烟测试
├── Packages/
│   ├── GlintCore/             # 领域模型、协议、路由和缓存
│   ├── GlintMac/              # Accessibility、TIS 和实时监控
│   ├── GlintDictionary/       # SQLite 词典与排序
│   ├── GlintInference/        # CTranslate2 与 MLX 推理
│   ├── GlintPlugins/          # 插件清单、下载、导入和安装
│   ├── GlintUI/               # 主窗口、设置和 HUD
│   └── GlintBenchmark/        # 词典基准命令行
├── Bridges/
│   └── CTranslate2Bridge/     # C ABI 源码；运行时 dylib 随 OPUS 资源提供
├── Tools/
│   ├── AXCandidateLab/
│   ├── CandidateLab/
│   ├── DictionaryBuilder/
│   ├── DictionaryLab/
│   ├── GlintEval/
│   └── ModelLab/
├── Resources/
│   ├── Distribution/
│   ├── Evaluation/
│   ├── Plugins/
│   └── catalog.json
├── docs/
│   ├── ARCHITECTURE.md
│   ├── AX-CANDIDATE-VALIDATION.md
│   ├── DICTIONARY-SOURCES.md
│   ├── RELEASE-PLAN.md
│   └── assets/
├── scripts/
│   ├── build.sh
│   ├── dev.sh
│   ├── launch.sh
│   ├── package_test_dmg.sh
│   ├── prepare_opus_model.sh
│   ├── run.sh
│   ├── test.sh
│   ├── verify_app.sh
│   └── build_wiktionary_dictionary.py
```

## 4. 模块边界

### GlintCore

纯 Swift，不依赖 AppKit 或数据库。

包含：

- `Candidate`、`CandidateKind`、`TranslationResult`、`TranslationMode`；
- `DictionaryEngine`、`TranslationEngine` 协议；
- `SmartRouter`：词典/模型/不显示的路由；
- `TranslationMemo`：精确结果内存缓存和并发请求合并；
- `TypingActivityTracker`：候选停留和 revision 计算；
- 公共错误类型、模型选择偏好和提示词档位。

### GlintMac

所有 macOS 平台相关实现：

- TIS 输入源判断；
- Accessibility 光标/控件 frame；
- Accessibility 输入法候选读取；
- 安全输入判断；
- `MonitoringController`、候选去抖和整栏翻译调度；
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
- `MainWindowModel` 作为主窗口的 `@MainActor` 状态和动作边界；
- 依赖 `GlintCore` 的领域类型和 `GlintPlugins` 的 manifest/manager
  接口，不直接实现 Accessibility 读取或推理。

### GlintApp

组合根，只做：

- App 生命周期；
- 创建 `AppEnvironment`；
- 注入具体实现；
- 菜单栏、主窗口、HUD 的协调；
- 权限引导和启动/停止监控。

### Tools/ModelLab

Python 模型实验环境：

- 模型下载和转换；
- 50 条测试集；
- 质量、延迟、内存评测；
- 将选型结论记录到实验工具说明和提交历史。

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
- `Bridges/CTranslate2Bridge` 的运行时产物只由 `GlintInference` 通过 C ABI
  `dlopen` 加载；桥接源码不进入 Swift 依赖图。

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
- 候选 reader 输出 `AXCandidateGeometry`，分别说明横向锚点和纵向边界来自
  `window`、`list`、`item` 还是 `text` 节点。文字节点补足候选胶囊的视觉留白，
  `window` 节点去除默认皮肤约 `8pt` 的透明上下边距，其余控件节点保持原始
  frame；HUD 只消费归一化后的边界。
- HUD 的用户间距从上述归一化边界计算；屏幕边缘优先翻边，避免为了贴边而静默
  压缩间距。
- 主窗口和 HUD 都通过 `AppEnvironment` 获取状态，不直接互相调用。

## 7. 运行时数据流

```text
InputSourceMonitor (TIS)
  → InputMethodIdentity + InputSourceKind
  → FocusMonitor (AX)
  → CandidateReaderRouter
      ├─ AXCandidateReader (standard candidate list)
      ├─ WeTypeCandidateReader (WeChat-specific AX structure)
      ├─ SogouCandidateReader (Sogou anonymous candidate list)
      └─ AdaptiveUnknownCandidateReader (background discovered Profile)
  → SmartRouter (GlintCore)
      ├─ DictionaryEngine (GlintDictionary)
      └─ TranslationEngine (GlintInference)
  → HUDController (AppKit + SwiftUI)
```

主窗口只是观察同一套状态：

```text
MonitoringSession → AppDelegate + HUDEventCoordinator
MainWindowModel → MainWindowView
```

## 8. 并发与状态

- `MonitoringController`：actor；单一轮询循环，负责权限节流、候选去抖、
  停留判定、翻译取消和事件发布。
- `MonitoringSession`：actor；串行化 start/stop 意图，长期持有
  `MonitoringController` 的事件流，向 AppDelegate 发布状态和监控事件。
  停止监控只停止轮询循环，不取消事件消费者，因此重新开启后事件仍然可达。
- `AppDelegate`：仅在 `MonitoringSession` 报告 running 后把 UI 置为已开启；
  启动准备期间显示 preparing 状态；事件泵在 App 生命周期内不取消。
- `AXCandidateReader`：候选识别主路径；只识别具有输入法候选语义的
  `InputMethodCandidateList`，不读取普通 `AXList`。通过 FocusSnapshot 的
  focused PID 复用焦点解析结果，避免每次轮询重新查找 focused application。
- `InputMethodIdentity`：GlintCore 中的系统输入法身份，包含 bundle ID、input
  source ID、source type 和本地化名称。UI 展示使用 TIS 的本地化名称，不用内部
  ID 猜测输入法名称。
- `CandidateReaderRouter`：按 bundle ID / input source ID 把输入法路由到专用
  candidate reader；未知输入法使用标准 reader。新增搜狗等输入法只需注册 reader
  和 adapter，不增加 `MonitoringController` 分支。
- `AdaptiveUnknownCandidateReader`：组合输入中标准 reader 未命中时异步探测当前
  输入法进程；只接受已验证的独立单行列表或文字样式 Profile。探测不阻塞候选轮询，
  一个进程内全局最多执行一个探测，并按输入源缓存正向或负向结果。成功 Profile
  以输入法版本为边界持久化到 `UserDefaults`，失败结果只在内存中保留冷却。
- `WeTypeCandidateReader`：微信输入法专用候选路径；从 `WeType` 进程读取候选
  文本、frame 和 `AXAttributedStringForRange` 前景亮度。唯一亮色数字对应的组
  作为高亮候选；无法判断样式时使用首候选，不截图且不申请屏幕录制权限。
- `SogouCandidateReader`：从 `SogouInput` 进程的匿名 `AXList` 读取单行可见候选
  和 frame。公开 AX 不提供高亮项，因此默认“选中”模式使用首候选，并返回
  `selectionIsExact=false`；用户选择“一栏”时翻译可见候选但不伪造选中高亮。
- `AXCandidateGeometry`：统一候选几何语义。横向锚点和纵向边界可以来自不同节点；
  文字节点与控件节点使用不同视觉补偿，避免把输入法名称写进 HUD 布局分支。
  `window` 的固定内缩以搜狗默认皮肤为基线；第三方皮肤不单独检测，由用户间距兜底。
- `CandidateTranslationPipeline`：无状态并发编排；选中项优先，整栏结果按
  revision 发布，旧任务由监控层取消。
- `TranslationRuntime`/`TranslationMemo`：actor；模型加载、推理和缓存请求串行化。
- `PluginManager`/`PluginCatalogService`/`LocalModelImportService`：actor；
  下载、导入和安装进度通过闭包回到主 actor。
- `MainWindowModel`/`HUDController`：`@MainActor`；只接收不可变的展示状态。
- 缓存：内存 LRU；不落盘；候选变化时取消旧请求。

未知输入法的 Profile 探测、缓存和限流细节见
`docs/GENERIC-INPUT-METHOD-ADAPTATION.md`。

## 9. 插件与模型

- 插件 manifest 是唯一入口；模型/词库是数据，不带可执行代码。
- 支持两种插件类型：`dictionary`、`translation`。
- 固定运行时适配器：
  - `cedict-sqlite` → CC-CEDICT 查询与 overrides；
  - `ecdict-rank` → ECDICT 词频和义项排序；
  - `sqlite-v1` → 扩展词典；
  - `ctranslate2` → CTranslate2Bridge；
  - `mlx` → MLX Swift。
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
  刷新内存中的已安装清单。
- 删除流程：先取消推理/卸载模型，再删除插件目录。核心词典和
  内置 OPUS-MT 不提供删除操作。
- 不支持任意第三方 dylib、脚本或可执行文件。
- 下载和本地导入的翻译插件只允许 MLX；词典插件只允许固定 SQLite runtime。
  CTranslate2 只从签名的 App bundle 加载。
- 不支持用户添加的远程翻译接口；候选和翻译内容只进入受支持的本地运行时。
- 插件升级使用持久化事务标记；未完成激活的升级在下次启动时回滚到旧版本。
- 产品语言固定为简体中文到英文；清单不重复保存 capabilities、语言或质量档位。

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
  - CTranslate2 与 SentencePiece 动态库（运行在 `Resources/Plugins/mt-opus-zh-en/bin`）。
- App target 只复制运行时 allowlist：`catalog.json`、`dict-cedict`、
  `dict-ecdict`、`dict-wiktionary-zh-en` 和 `mt-opus-zh-en` 五个只读核心
  资源。OPUS-MT 权重由构建脚本准备且不进入 Git；评测数据、可选插件和其他
  模型目录不得由 `Resources` 整目录进入 App。
- App 第一版不启用 App Sandbox；使用 Developer ID + hardened runtime + 公证。
- Bundle ID 暂定 `com.local.glint`，正式签名/团队确定后再改。
- `scripts/build.sh`、`scripts/test.sh` 只封装 `xcodebuild`/`swift test`，不复制 demo 的 `swiftc` 流程。

## 12. 测试

### 单元测试

- `SmartRouter` 的双来源路由、失败回退和无结果；
- 候选文本清洗、数字/emoji 过滤；
- 词典英文对应词排序；
- manifest 校验、版本比较、安装状态机；
- 翻译取消和缓存。

### 集成测试

- 用 AX 候选快照和 frame 数据测试 MonitoringController；
- 用 mock `TranslationEngine` 测试 HUD 显示/隐藏；
- 主窗口侧栏、插件下载状态、权限提示的 UI 测试。

### 模型评测

- `Tools/ModelLab` 生成 50 条测试集；
- 对比 OPUS-MT、Qwen3、Hy-MT2 和 Index-Translate；
- 记录：英文对应准确率、短句自然度、p95 延迟、峰值内存、模型体积；
- 结果保留在版本历史和实验工具说明中，生产运行时只接入经过验证的模型类型。

## 13. ADR 列表

- ADR-0001：不替换输入法，采用候选栏读取 + HUD；输入候选由 AX 读取。
- ADR-0002：Swift 6 + AppKit/SwiftUI 混合。
- ADR-0003：插件模型作为数据，固定 runtime adapter。
- ADR-0004：AppKit 生命周期承载菜单栏 + 主窗口 + HUD。
- ADR-0005：先做 ModelLab，再接入经过验证的生产推理运行时。
- ADR-0006：不持久化候选文本和翻译结果。
