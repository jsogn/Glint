# Glint Architecture

- 状态：现行
- 最近校准：2026-10-30
- 平台：macOS 15+，Apple Silicon
- 语言：Swift 6

## 1. 架构目标

Glint 是菜单栏工具、主窗口和单行 HUD 组成的 macOS App：

1. 使用原生 Accessibility、TIS 和 AppKit 集成；不截图、不执行 OCR。
2. 全局默认生效，但只读取当前输入法候选，不读取输入框正文。
3. CC-CEDICT 与 ECDICT 是只读内置词典能力；Apple Translation
   是默认翻译模型，OPUS-MT 是可安装、可卸载的在线模型数据。
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
| 词典 | SQLite3、CC-CEDICT、ECDICT |
| 默认翻译 | Apple Translation |
| 轻量可选翻译 | 在线 OPUS-MT 数据 + App 内置 CTranslate2 int8 运行库 |
| 可选翻译 | MLX Swift，下载或本地导入 |
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
| `GlintRimeRelayCore` | Rime 候选协议、Socket Client 和本地 Socket Server |
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

### GlintRimeRelayCore

- Rime 候选协议、经过校验的候选快照模型。
- Unix Domain Socket Client 和 Server。
- 只依赖 Foundation/Darwin，不依赖 AppKit、GlintMac 或业务模块。
- `RimeCandidateBridge` 只依赖该模块；无关 App 源码变化不得要求提升
  Rime 资产版本。

### GlintMac

- 当前输入源、焦点、文字选区、Secure Input 和辅助功能状态。
- `MonitoringController` actor：权限节流、候选轮询、停留、取消和事件发布。
- 候选轮询按权限/输入源、焦点目标、候选读取、活动判定和翻译触发分阶段执行；
  actor 仍集中持有会话状态，避免把并发状态分散到多个对象。
- `CandidateReaderRouter`：Apple、显式 reader 和未知输入法 Profile。
- Rime 候选 Socket、快照存储和鼠须管 Reader；在所有构建中注册。
- `RimeSupportPaths`：统一提供正式支持目录和 Socket 路径。
- `SquirrelIntegrationService`：启用 schema 解析、YAML 预检、事务安装、
  备份、哈希校验、重新部署和回滚；在 App 组合根中构造。
- Apple Translation 系统会话协调器、系统翻译 Engine 和持久
  `translationTask` 宿主。系统翻译以保留模型 ID
  `system-apple-translation` 参与现有 `TranslationEngine` 路由。
- 每次“安装语言包”或“继续安装”都会创建新的翻译会话配置；关闭系统下载
  窗口不会把仍受支持的语言包标记为安装失败。准备中断后，协调器低频读取
  `LanguageAvailability`，完成时主动通知界面刷新，不伪造系统下载进度。
- 语言资源由 macOS 管理；Glint 只在用户主动安装或资源已安装时连接会话，
  不在候选翻译期间触发下载。选择系统翻译后释放 OPUS-MT/CTranslate2 容器；
  系统翻译失败时不自动加载其他翻译模型，由现有路由决定是否使用词典路径。
  等待 SwiftUI 宿主挂载会话有两秒上限，避免登录启动或窗口重建时阻塞整个
  运行时。
- `AXReadSession`：消息超时、属性调用上限和总截止时间。
- 不包含 UI、插件下载、词典数据或推理实现。

### GlintDictionary

- 查询 CC-CEDICT 和 ECDICT SQLite 资源。
- 生产数据库使用紧凑 schema-v3：CC-CEDICT 将查询词项与义项归一化为
  `terms`/`senses`，ECDICT 使用 `(term, english)` 的 `WITHOUT ROWID`
  主键表；不保留运行时未使用的拼音或重复排序索引。
- CC-CEDICT 精确命中时作为权威来源返回，并继续使用 ECDICT 词频信号提升
  CC-CEDICT 支持的英文头词；只有当权威结果少于三项时，才允许带考试标签的
  ECDICT 词作为低优先级补充。ECDICT 和用户词典默认按优先级依次
  作为回退，独立回退结果不追加到权威结果中。
- 词典候选进入 HUD 前统一过滤长句和解释性 gloss；权威来源只有释义时不算命中，
  继续回退到简明词典或本地模型。
- 通过固定 runtime 接口加载词典插件，不执行插件代码。

### GlintInference

- `TranslationEngine` 的 CTranslate2 与 MLX 实现。
- CTranslate2 运行库只从签名 App bundle 加载；OPUS-MT 模型数据只从受控的
  `Application Support/Glint/plugins/mt-opus-zh-en` 目录加载。
- 可选模型接受 MLX 数据插件，以及固定 ID 的 OPUS-MT
  `ctranslate2-data` 数据包；不负责 UI 或候选读取。
- 负责模型生命周期、推理串行化和资源释放。

### GlintPlugins

- 解析 manifest，校验版本、文件类型和 SHA256。
- 下载、镜像回退、断点进度、解压和原子安装。
- 管理可选词典与翻译模型；内置核心能力不参与安装或卸载。
- App 启动时检查已安装核心词典；旧 schema 或不兼容缓存使用 bundled 数据原子
  修复，失败时保留旧目录并继续回退 bundled 基线。
- 插件是数据包，不允许携带 dylib、脚本或其他可执行代码。

### GlintUI

- 主窗口侧栏、设置页、插件页、权限页和关于页。
- “输入法支持”页展示 Rime 正式支持状态和安装引导。
- 单一 HUD panel，不创建键盘监听、Toast 或运行时错误卡片。
- `MainWindowModel` 作为 `@MainActor` 展示状态和动作边界。
- 不直接实现 Accessibility 读取或模型推理。

### GlintApp

- 创建 `AppEnvironment` 并注入具体实现。
- 管理菜单栏、主窗口、HUD、监控 session 和退出。
- 仅在翻译运行时准备完成后启动监控。
- 所有构建都启动 Rime Socket 接收器并注入事务安装器。已安装候选读取支持使用
  独立的资源版本；App 更新后仅在资源或协议版本变化时自动迁移，未安装用户不会
  自动写入 Rime 配置。组合根让安装器和 Socket 使用同一正式目录。Release
  保留并签名中继 helper 和 Lua 资源。
- Rime 安装器在进程锁和跨进程锁内执行，只写发生变化的目标，并用事务日志、
  字节级原件备份、SHA256 和权限校验支持失败回滚与崩溃后恢复。用户自有的
  filter、注释、空键和受管文件改动不会被自动覆盖或删除。
- 保持单实例并提供 readiness 与诊断命令。

## 5. 依赖方向

```text
GlintApp
  → GlintUI / GlintMac / GlintDictionary / GlintInference / GlintPlugins

GlintUI
  → GlintCore / GlintPlugins

GlintMac / GlintDictionary / GlintInference / GlintPlugins
  → GlintCore

GlintMac
  → GlintRimeRelayCore

RimeCandidateBridge
  → GlintRimeRelayCore

GlintRimeRelayCore
  → 无 AppKit / SQLite / MLX 依赖

GlintCore
  → 无 AppKit / SQLite / MLX 依赖
```

- 禁止反向依赖，尤其禁止 `GlintCore` 引用平台、数据库或推理模块。
- `GlintMac` 不引用 `GlintUI`；`GlintInference` 不引用 `GlintPlugins`。
- UI 只依赖领域协议，不直接持有 CTranslate2 或 MLX 类型。
- `Bridges/CTranslate2Bridge` 只由 `GlintInference` 通过 C ABI 加载。

## 6. 生命周期与 UI

- `LSUIElement = true`，App 仅驻留菜单栏。
- 菜单栏开启和关闭状态共用 `16×16` 模板图标画布；关闭状态使用降透明度的
  暂停变体，不通过独立标题或额外圆点改变状态栏项宽度。
- 首次启动显示主窗口；关闭窗口只隐藏，不停止监控。
- 登录时启动由 `SMAppService.mainApp` 管理，默认关闭；登录启动只进入菜单栏，
  不主动显示主窗口。
- 不使用 AppKit 的自动登录恢复，避免与登录项重复启动。
- 翻译运行时准备完成后才启动 `MonitoringSession`。
- “智能融合”并行查询模型与词典，以模型/词典共识和双方排序综合结果；“词典
  优先”保持词典结果在前，“模型优先”保持模型结果在前。完整句子优先使用
  本地模型，模型失败时回退词典。
- HUD 使用 borderless、non-activating `NSPanel`，加入所有 Space 与全屏空间。
- HUD 不抢焦点、不改变候选选择，也不创建新的内容根视图。
- 选中模式中，4 字以内的候选如果已有至少两条简洁释义，会隐藏超过 8 个
  英文词或 48 个字符的解释性候选；显示项与数字快捷键使用同一过滤后数组。
- 自动定位根据候选栏与光标矩形的相对位置避开输入行：候选栏在输入行上方时，
  HUD 放上方；在下方时放下方；缺少可靠几何时默认下方。首选侧放不下时回退到
  另一侧。底部、顶部和左右都直接使用系统可见区域边界，不额外留白。标准
  `AXBoundsForRange` 缺失或返回零高度
  矩形时，可对折叠文本选区尝试 `AXBoundsForTextMarkerRange`；只接受位于文本框
  内、宽度不超过 4pt 的 marker 光标，整控件范围或其他异常范围必须丢弃。翻转后
  如果 HUD 与输入光标所在行重叠，且原始位置仍侵入光标右侧安全线，优先把完整
  HUD 放到光标右侧；候选栏本来已经在安全线外时保持候选对齐，不追随光标。右侧
  空间不足时，再沿当前候选方向越过该输入行。左对齐文本通常位于光标左侧，因此
  不把“光标左侧”作为安全位置。
- HUD 显示后继续监听候选栏和输入光标的几何变化；移动超过 2pt 时只重排现有
  panel，不增加翻译 revision、不重新翻译，也不重置淡化状态。翻译结果完成时
  使用当前最新光标位置，而不是开始翻译时的位置。
- “插入译文”不读取输入框正文，也不写入系统剪贴板。插入前结束当前输入法组合，
  通过定向到已校验宿主进程的 HID 键盘事件发送 Unicode 文本。发送前后都校验
  PID、AX 输入控件身份、可编辑状态、文字选区和 Secure Input；任一项变化即静默
  放弃。插入失败会恢复当前候选的快捷键，offer 已变化时不会恢复旧快捷键。
- 主窗口和 HUD 都通过 `AppEnvironment` 获取状态，不互相直接调用。
- 监控、候选 reader 和 HUD 均跳过 Glint 自身 PID。

候选 reader 输出 `AXCandidateGeometry`，区分横向锚点和纵向边界来自 `window`、
`list`、`item` 还是 `text`。输入法专属视觉校准由 reader 完成，HUD 只消费最终
presentation frame。苹果简体拼音的候选 item frame 包含上下各 `2.5pt` 的装饰
留白；专属 reader 只缩放派生纵向边界，原始 item frame 仍用于候选跟踪。panel
是唯一尺寸来源，`NSHostingView` 不得反向压缩窗口高度。

## 7. 运行时数据流

```text
InputSourceMonitor (TIS)
  → InputMethodIdentity
  → FocusMonitor
  → CandidateReaderRouter
      ├─ AXCandidateReader
      ├─ 微信 / 搜狗显式 reader
      ├─ 鼠须管 Lua 候选桥
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

选中项产生译文后，`MonitoringController` 还会发布仅在内存中存在的
`TranslationChoiceOffer`。界面默认最多显示四个翻译项，用户可在 `1–9`
范围内调整上限；选中模式限制独立释义数量，一栏模式限制参与翻译的前 N 个
可见候选，超出上限的候选不会创建翻译任务。只要当前译文
有效，`TranslationChoiceShortcutCoordinator` 就临时注册用户在“通用配置”中通过
本地录制控件配置的释义插入触发修饰键，默认是 `Option`。选中模式将独立释义显示
为 `1–N` 序号，且不使用候选高亮；多个释义按自然文字宽度排列，间距默认
`14pt`，用户可在 `8–24pt` 范围内调整。选中模式左右使用对称的内容内边距，
不与一栏模式的候选槽位边距复用。
白名单只包含 Control、Option、Command、Shift 和 Caps Lock，允许组合使用。
录制仅在设置控件获得焦点时处理按键，不安装全局键盘监听。
存在有效译文时，Glint 只按当前已发布选项数量动态注册
“触发修饰键 + 数字”热键，两种模式都按用户上限注册 `1–N`。未显示或未发布
的序号不会注册，也不会触发插入。
“释义插入”开关关闭时保留已录制的触发键，但不注册任何数字选择热键。
触发键只接受当前 revision；候选变化、Secure Input 或监控停止都会立即撤销。
“一栏”模式按候选序号发布整行可见候选的首选翻译；任一 `触发键 + 数字`
都插入该序号对应的译文，不要求该候选当前处于高亮状态。

未知输入法的 Profile、资源上限和失败恢复见
[未知输入法通用适配](GENERIC-INPUT-METHOD-ADAPTATION.md)。AX 结构、性能和验收
边界见 [AX Candidate Validation](AX-CANDIDATE-VALIDATION.md)。

鼠须管的 AX 候选窗没有候选级语义。Glint 可通过用户侧 `librime-lua`、本地中继
和 Unix Domain Socket 接收候选与选中索引；其他输入法不经过该路径。
“输入法支持”页的安全安装器先解析
Rime `schema_list`，只修改已启用且已编译的方案；遇到复杂 YAML 会在写入前
停止。安装、修复和卸载均带备份、哈希与失败回滚。Squirrel 不暴露候选面板
frame 时，仅该 Reader 回退到宿主输入光标作 HUD 锚点。详见
[鼠须管候选桥接说明](SQUIRREL-CANDIDATE-BRIDGE.md)。

## 8. 候选读取与监控

- `MonitoringController` 是单一 actor 轮询循环；权限检查最多每秒一次。
- 快速输入期间保持 `40ms`，候选停留并启动翻译后降至 `80ms`。
- 候选变化恢复快速轮询；不增加翻译完成后的固定等待。
- 确定性候选结束和多行布局立即关闭 HUD；不确定 AX 失败使用两帧去抖。
- 标准候选缓存验证窗口和列表归属；分组文本项缓存额外验证父链、子节点数量和
  候选项身份。
- 已知 Profile 按 Bundle 与输入源复用，版本号只记录最近验证结果；读取失败时先
  回退标准 reader；同版本连续无法识别也进入恢复。后台探测全局单任务，使用有
  上限的渐进退避，并以每输入源 generation 拒绝过期结果。
- 同一输入源的交互读取和探测读取串行化；不同输入源使用独立读取租约。
- 进程 fallback 只对 Apple、显式 reader 和已验证 Profile 开放，不猜测文本框。
- Apple 拼音读取失败时可按宿主 PID 请求一次增强 AX；写入后必须回读确认。
- 权限状态按秒节流，不在每次候选轮询重复调用 TCC。

## 9. 并发与状态

- `MonitoringController` 串行化输入源、焦点、候选、停留和翻译任务状态。
- `MonitoringSession` 串行化 start/stop 意图，并长期持有事件流。
- 插入选项和快捷键只在存在有效译文时存在；不轮询或保存普通键盘输入。
- `AppDelegate` 只在 session 报告 running 后把 UI 置为已开启。
- `TranslationRuntime` 和 `TranslationMemo` 串行化模型加载、推理和请求合并。
- `PluginManager`、目录服务和本地导入服务以 actor 隔离文件操作。
- `MainWindowModel` 和 `HUDController` 保持在 `@MainActor`。
- `MainWindowModel` 是设置窗口范围内唯一的可观察协调状态；下载器、安装事务和
  翻译运行时仍由独立模块执行。`GlintUI` 对 `GlintPlugins` 的依赖仅用于 manifest、
  市场摘要、进度和生命周期适配，不在视图层直接访问 URLSession、下载文件或数据库。
- 候选 revision 变化时取消旧翻译；只允许当前 revision 更新 HUD。
- 候选、翻译结果和输入历史不落盘；精确结果缓存只在内存中使用。

## 10. 插件与模型

- manifest 是插件唯一入口，支持 `dictionary` 与 `translation`。
- 固定 runtime：
  - `cedict-sqlite`、`ecdict-rank`、`sqlite-v1`；
  - `ctranslate2-data` 仅用于在线 OPUS-MT；
  - `mlx` 用于可选翻译模型。
- CC-CEDICT、ECDICT 随 App 提供，不允许卸载。CC-CEDICT 与 ECDICT
  可把经过校验的更新安装到 Application Support 的同 ID 数据目录，加载失败时
  回退 bundled 基线。
- OPUS-MT 不在 App 内。用户下载后安装到 Application Support，并可切换到
  Apple Translation 后卸载。在线包只能携带模型数据，运行时始终来自签名 App。
- CC-CEDICT 仅允许用户手动从 MDBG 官方地址检查更新。更新器使用 HEAD 条件请求、
  同日 ETag 变化检测、gzip 流式解析、schema/数量/完整性校验和可回滚的原子插件
  安装；取消或失败不会替换当前可用词典。
- ECDICT 仅允许用户手动检查更新。更新器读取 GitHub 的 `ecdict.csv` 提交 Atom
  源检测 revision，下载固定 revision 的官方代码归档，流式解压并校验 CSV 结构，
  随后重建排序 SQLite 并执行同样的数量、完整性和可回滚安装校验。
- CC-CEDICT 与 ECDICT 的发布资源更新和 App 内更新共用 `GlintDictionary` 中的
  Swift 构建器。
- 可更新能力由 manifest 的 `coreUpdateKind` 声明，设置页与服务分发不再各自维护
  词典 ID 白名单。核心词典更新在 App 层全局串行，避免多个安装事务竞争。
- OPUS-MT 由 `scripts/prepare_opus_model.sh` 按固定 revision 转换并校验，
  由 `scripts/package_opus_model_data.sh` 生成固定 SHA256 的在线数据包。
  权重不进入 Git 或 App，运行库由 `runtime-lock.json` 固定。
- 可选 MLX 模型优先国内镜像，失败后回退官方源；下载、校验和安装阶段不重叠。
- Hugging Face 镜像顺序、URL 会话和远程地址白名单由单一策略统一提供；模型快照
  下载按来源选择、单文件下载、磁盘检查、进度上报和 SHA256 校验拆分。
- MLX 模型按 profile 使用官方输入协议和解码参数：Hy-MT2 使用单条 user 翻译
  模板与官方采样参数，Index-Translate 使用贪心解码并关闭 thinking，Qwen 使用
  system/user 分离。未知导入模型只发送原文；短输入出现指令回显时静默回退词典。
- 市场模型首先用仓库名、`base_model` 元数据和已知 profile 识别模型族。未知
  MLX 模型安装后依次探测直接原文、翻译指令和 system 指令，使用短词输出、语言、
  长度和指令回显检查选择协议，并把结果写入模型目录内的隐藏文件
  `.glint-translation-adapter.json`。模型目录升级替换时缓存随之失效并重新探测。
- 翻译模型更新的检查结果和检查时间按模型持久化。进入“翻译模型”页面只读取
  缓存，不自动联网；App 启动后仅自动检查当前模型，成功冷却 6 小时、失败冷却
  15 分钟。行内“检查更新”由用户主动触发，并绕过冷却。
- 模型市场直接查询 Hugging Face / 国内镜像的上游仓库，不需要维护远端目录服务。
  搜索只负责发现；下载前读取 `config.json`、文件清单和 tokenizer 信息，并检查
  当前 MLX runtime 是否支持该 `model_type`。
- 空查询浏览上游翻译分类；主动搜索覆盖全部 MLX 模型，不因用途标签或内存估算
  隐藏结果，也不根据搜索元数据显示兼容结论。点击安装后才对固定 revision 执行
  架构、文件、tokenizer 和内存检查，并显示确定原因。
- 安装前检查通过后先展示模型架构、参数规模、量化精度、精确下载大小、预计运行
  内存、许可证和 revision；用户确认后才开始下载。
- 市场新模型下载后会在提交安装前加载并执行一次短句翻译；失败时卸载新模型并
  恢复原模型，成功时保持在原有模型选择上。
- 已安装模型通过上游 commit SHA 检查更新，不使用手工版本号判断。市场安装和更新
  都固定具体 revision；带 revision 的快照不读取可变化的 ModelScope `master`。
- 插件升级使用持久化事务；未完成激活的升级在下次启动时回滚。
- 不支持用户添加的远程翻译接口，候选与译文只进入本地受支持运行时。

## 11. 持久化、构建与测试

- 词典为只读 SQLite；模型为本地目录；偏好保存到 UserDefaults/JSON。
- 不保存候选文本、译文、输入历史、剪贴板或窗口标题。
- 译文插入不使用剪贴板，不读取输入框正文；仅使用选区范围、组合状态和宿主 PID
  判断是否允许写入。
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
