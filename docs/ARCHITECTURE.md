# Glint Architecture

- 状态：现行
- 最近校准：2026-10-26
- 平台：macOS 26+，Apple Silicon
- 语言：Swift 6

## 1. 架构目标

Glint 是菜单栏工具、主窗口和单行 HUD 组成的 macOS App：

1. 使用原生 Accessibility、TIS 和 AppKit 集成；不截图、不执行 OCR。
2. 全局默认生效，但只读取当前输入法候选，不读取输入框正文。
3. CC-CEDICT、ECDICT、Wiktionary 和 OPUS-MT 是只读内置能力。
4. 翻译运行时可以替换，但插件只能携带受支持的模型或词典数据。
5. 默认不保存候选文本、翻译结果或输入历史。
6. 模型评测与生产运行时分离，只接入经过验证的运行时类型。

## 2. 技术栈

| 层 | 选型 |
| --- | --- |
| App 生命周期 | AppKit `NSApplicationDelegate` |
| 主窗口 | AppKit `NSWindow` + SwiftUI `NSHostingController` |
| HUD | 单一 AppKit `NSPanel` + 持久 SwiftUI `NSHostingView` |
| 候选读取 | Accessibility 标准候选、显式 reader、结构 Profile |
| 输入状态 | Carbon TIS + Accessibility |
| 词典 | SQLite3、CC-CEDICT、ECDICT、Wiktionary |
| 轻量翻译 | 内置 CTranslate2 int8（OPUS-MT） |
| 可选翻译 | MLX Swift，本地下载或导入 |
| 插件管理 | manifest、SHA256 校验和原子安装 |
| 日志 | OSLog，默认脱敏 |
| 分发目标 | Developer ID、hardened runtime、公证；当前测试发布见发布计划 |

## 3. 仓库结构

```text
Glint/
├── App/                 # 组合根、生命周期、菜单栏和诊断入口
├── Packages/            # 领域、macOS、词典、推理、插件和 UI 模块
├── Bridges/             # CTranslate2 C ABI 桥接源码
├── Tools/               # 候选、词典和模型实验工具
├── Resources/           # 内置核心能力、模型清单和分发资源
├── docs/                # 现行架构、验证、发布和来源文档
└── scripts/             # 构建、测试、运行、打包和校验入口
```

`docs/` 只保留长期维护的现行事实、验证证据和发布门禁。已完成里程碑、重复实验
记录和已被现行文档覆盖的专项调研由 Git 历史保存。

## 4. 模块边界

| 模块 | 职责 |
| --- | --- |
| `GlintCore` | 纯 Swift 领域模型、词典/翻译协议、路由、停留判定和精确缓存 |
| `GlintMac` | TIS、Accessibility、候选 reader、焦点、安全输入和监控编排 |
| `GlintDictionary` | SQLite 查询、词频排序和词典插件加载 |
| `GlintInference` | CTranslate2、MLX、模型加载、内存预算和推理取消 |
| `GlintPlugins` | manifest、下载、校验、原子安装和本地模型导入 |
| `GlintUI` | 主窗口、设置、HUD、权限页和展示状态 |
| `GlintApp` | 组合根、App 生命周期和跨模块协调 |

### GlintCore

- `Candidate`、`CandidateKind`、`TranslationResult` 和翻译模式。
- `DictionaryEngine`、`TranslationEngine` 和 `SmartRouter`。
- `TranslationMemo`：精确结果 LRU、并发请求合并和容量限制。
- `TypingActivityTracker`：候选停留、revision 和快速输入抑制。
- 不依赖 AppKit、SQLite 或任何推理运行时。

### GlintMac

- 当前输入源、焦点、文字选区、Secure Input 和辅助功能状态。
- `MonitoringController` actor：权限节流、候选轮询、停留、取消和事件发布。
- `CandidateReaderRouter`：Apple、显式 reader 和未知输入法 Profile。
- `AXReadSession`：消息超时、属性调用上限和总截止时间。
- 不包含 UI、插件下载、词典数据或推理实现。

### GlintDictionary

- 查询 CC-CEDICT、ECDICT 和 Wiktionary SQLite 资源。
- 合并多来源义项，按词频、短语和人工 override 排序。
- 通过固定 runtime 接口加载词典插件，不执行插件代码。

### GlintInference

- `TranslationEngine` 的 CTranslate2 与 MLX 实现。
- 内置 OPUS-MT 只从签名 App bundle 加载。
- 可选模型只接受 MLX 数据插件；不负责下载、UI 或候选读取。
- 负责模型生命周期、推理串行化和资源释放。

### GlintPlugins

- 解析 manifest，校验版本、文件类型和 SHA256。
- 下载、镜像回退、断点进度、解压和原子安装。
- 管理可选词典与翻译模型；内置核心能力不参与安装或卸载。
- 插件是数据包，不允许携带 dylib、脚本或其他可执行代码。

### GlintUI

- 主窗口侧栏、设置页、插件页、权限页和关于页。
- 单一 HUD panel，不创建键盘监听、Toast 或运行时错误卡片。
- `MainWindowModel` 作为 `@MainActor` 展示状态和动作边界。
- 不直接实现 Accessibility 读取或模型推理。

### GlintApp

- 创建 `AppEnvironment` 并注入具体实现。
- 管理菜单栏、主窗口、HUD、监控 session 和退出。
- 仅在翻译运行时准备完成后启动监控。
- 保持单实例并提供 readiness 与诊断命令。

## 5. 依赖方向

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

- 禁止反向依赖，尤其禁止 `GlintCore` 引用平台、数据库或推理模块。
- `GlintMac` 不引用 `GlintUI`；`GlintInference` 不引用 `GlintPlugins`。
- UI 只依赖领域协议，不直接持有 CTranslate2 或 MLX 类型。
- `Bridges/CTranslate2Bridge` 只由 `GlintInference` 通过 C ABI 加载。

## 6. 生命周期与 UI

- `LSUIElement = true`，App 仅驻留菜单栏。
- 首次启动显示主窗口；关闭窗口只隐藏，不停止监控。
- 登录时启动由 `SMAppService.mainApp` 管理，默认关闭；登录启动只进入菜单栏，
  不主动显示主窗口。
- 不使用 AppKit 的自动登录恢复，避免与登录项重复启动。
- 翻译运行时准备完成后才启动 `MonitoringSession`。
- HUD 使用 borderless、non-activating `NSPanel`，加入所有 Space 与全屏空间。
- HUD 不抢焦点、不改变候选选择，也不创建新的内容根视图。
- 主窗口和 HUD 都通过 `AppEnvironment` 获取状态，不互相直接调用。
- 监控、候选 reader 和 HUD 均跳过 Glint 自身 PID。

候选 reader 输出 `AXCandidateGeometry`，区分横向锚点和纵向边界来自 `window`、
`list`、`item` 还是 `text`。输入法专属视觉校准由 reader 完成，HUD 只消费最终
presentation frame。panel 是唯一尺寸来源，`NSHostingView` 不得反向压缩窗口高度。

## 7. 运行时数据流

```text
InputSourceMonitor (TIS)
  → InputMethodIdentity
  → FocusMonitor
  → CandidateReaderRouter
      ├─ AXCandidateReader
      ├─ 微信 / 搜狗显式 reader
      └─ AdaptiveUnknownCandidateReader
  → MonitoringController
  → SmartRouter
      ├─ DictionaryEngine
      └─ TranslationEngine
  → HUDController
```

主窗口观察同一套监控状态：

```text
MonitoringSession → AppDelegate + HUDEventCoordinator
MainWindowModel → MainWindowView
```

未知输入法的 Profile、资源上限和失败恢复见
[未知输入法通用适配](GENERIC-INPUT-METHOD-ADAPTATION.md)。AX 结构、性能和验收
边界见 [AX Candidate Validation](AX-CANDIDATE-VALIDATION.md)。

## 8. 候选读取与监控

- `MonitoringController` 是单一 actor 轮询循环；权限检查最多每秒一次。
- 快速输入期间保持 `40ms`，候选停留并启动翻译后降至 `80ms`。
- 候选变化恢复快速轮询；不增加翻译完成后的固定等待。
- 确定性候选结束和多行布局立即关闭 HUD；不确定 AX 失败使用两帧去抖。
- 标准候选缓存验证窗口和列表归属；分组文本项缓存额外验证父链、子节点数量和
  候选项身份。
- 已知 Profile 失败时先回退标准 reader；后台探测全局单任务并指数退避。
- 进程 fallback 只对 Apple、显式 reader 和已验证 Profile 开放，不猜测文本框。
- Apple 拼音读取失败时可按宿主 PID 请求一次增强 AX；写入后必须回读确认。
- 权限状态按秒节流，不在每次候选轮询重复调用 TCC。

## 9. 并发与状态

- `MonitoringController` 串行化输入源、焦点、候选、停留和翻译任务状态。
- `MonitoringSession` 串行化 start/stop 意图，并长期持有事件流。
- `AppDelegate` 只在 session 报告 running 后把 UI 置为已开启。
- `TranslationRuntime` 和 `TranslationMemo` 串行化模型加载、推理和请求合并。
- `PluginManager`、目录服务和本地导入服务以 actor 隔离文件操作。
- `MainWindowModel` 和 `HUDController` 保持在 `@MainActor`。
- 候选 revision 变化时取消旧翻译；只允许当前 revision 更新 HUD。
- 候选、翻译结果和输入历史不落盘；精确结果缓存只在内存中使用。

## 10. 插件与模型

- manifest 是插件唯一入口，支持 `dictionary` 与 `translation`。
- 固定 runtime：
  - `cedict-sqlite`、`ecdict-rank`、`sqlite-v1`；
  - `ctranslate2` 仅用于内置 OPUS-MT；
  - `mlx` 用于可选翻译模型。
- CC-CEDICT、ECDICT、Wiktionary、overrides 和 OPUS-MT 随 App 提供，不复制到
  Application Support，也不允许卸载。
- OPUS-MT 由 `scripts/prepare_opus_model.sh` 按固定 revision 转换并校验；
  权重不进入 Git，锁文件记录产物 SHA256。
- 可选 MLX 模型优先国内镜像，失败后回退官方源；下载、校验和安装阶段不重叠。
- 插件升级使用持久化事务；未完成激活的升级在下次启动时回滚。
- 不支持用户添加的远程翻译接口，候选与译文只进入本地受支持运行时。

## 11. 持久化、构建与测试

- 词典为只读 SQLite；模型为本地目录；偏好保存到 UserDefaults/JSON。
- 不保存候选文本、译文、输入历史、剪贴板或窗口标题。
- 推理阶段不联网；只有用户主动下载或更新插件时使用 URLSession。
- App target 只复制五个运行时核心资源，不从 `Resources` 整目录复制。
- Xcode workspace 使用本地 Swift packages；构建、测试和运行统一走 `scripts/`。
- 单元测试覆盖路由、候选分类、词典排序、插件状态、缓存和偏好边界。
- 集成测试使用 AX snapshot、frame 和 mock runtime 验证监控、HUD 和生命周期。
- Release 前运行完整测试、Release arm64 构建和分发校验。

## 12. 架构决策

- ADR-0001：不替换输入法，使用候选读取 + HUD。
- ADR-0002：Swift 6、AppKit 生命周期、SwiftUI 内容。
- ADR-0003：插件作为数据，固定 runtime adapter。
- ADR-0004：菜单栏、主窗口和单一非激活 HUD panel。
- ADR-0005：先完成本地评测，再接入生产推理运行时。
- ADR-0006：不持久化候选文本和翻译结果。
