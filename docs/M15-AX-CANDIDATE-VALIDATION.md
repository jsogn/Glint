# Glint M15 AX Candidate Validation

- 日期：2026-10-21
- 分支：`codex/validate-accessibility-candidate-reader`
- 机器：Apple M4 Pro、48GB、macOS 26.6.2（25G83）
- 输入法：Pinyin – Simplified（`com.apple.inputmethod.SCIM.ITABC`）
- 目标：确认 Apple 拼音候选能否通过公开 Accessibility API 读取，并评估用 AX 替代 OCR 的准确率、性能和覆盖范围

## 结论

AX 方案可行，并已接入正式监控链路作为输入候选识别来源。它直接读取候选列表
的文本元数据，当前输入链路不再调用 ScreenCaptureKit、截图、Vision 或 PP-OCR。

验证结果还修正了最初方案中的两个错误假设：

1. 候选列表不是只出现在 `SCIM_Extension` 进程的独立窗口中。实现必须从当前
   宿主 App 的 AX 窗口树查找候选列表。
2. 选中状态不能依赖候选按钮自身的 `AXSelected`。实测候选按钮的
   `AXSelected` 均为 `0`，可靠来源是父列表的 `AXSelectedChildren`。

## 实测 AX 结构

在 TextEdit 中输入 `ni` 后，可观察到：

```text
TextEdit AXWindow / AXDialog
└─ AXList  AXIdentifier = InputMethodCandidateList
   ├─ AXButton  AXTitle = 你   ← AXSelectedChildren
   ├─ AXButton  AXTitle = 尼
   ├─ AXButton  AXTitle = 泥
   └─ ...
```

候选按钮的：

- `AXTitle`：候选原文；
- `AXValue`：`nil`；
- `AXSelected`：`0`；
- `AXFrame`：当前候选的实际屏幕位置和尺寸。

按右方向键后，TextEdit 的选中项从“你”变为“尼”，frame 的 x 坐标同步移动。
输入 `nihao` 后读取到“你好”，可见候选包含“你好”“👋”“你好吗”等。
输入 `nihaoma` 后读取到“你好吗”。按 Escape 后候选列表消失。

Safari 地址栏也完成了相同验证：

- 输入 `ni` 后选中候选为“你”；
- 右方向键切换为“尼”；
- 候选 frame 从 `x=887` 移动到 `x=928`；
- 结束组合后候选立即消失。

这证明候选列表既不是 TextEdit 特例，也不依赖 Web 页面 DOM。

## 性能

### Release，候选已缓存

候选出现后连续采样 5 秒：

| 场景 | p50 | p95 | 最大值 |
| --- | ---: | ---: | ---: |
| Safari，固定 PID | 0.369ms | 1.150ms | 93.875ms |
| Safari，当前前台 App | 0.400ms | 1.758ms | 61.369ms |
| 跨候选切换的 8 秒片段 | 0.378ms | 1.557ms | 63.617ms |

热路径每轮只读取：

1. `AXSelectedChildren`
2. 选中项的 `AXTitle`
3. 选中项的 `AXFrame`

应用节点和候选列表节点会缓存。候选列表失效或没有选中项时重新发现。

### 首次发现和失配

- 首次发现候选约 35–94ms，包含创建应用节点、枚举窗口和定位候选列表；
- 没有候选时重新扫描窗口的 Debug/Release 混合样本约为 12–24ms；
- AX 消息偶发卡顿时仍出现数百毫秒长尾，单次最坏样本曾超过 3 秒。

因此不能把该方案描述为“始终零延迟”。正确结论是：

- 候选出现后的稳定读取成本很低；
- 首次发现有一次数十毫秒成本；
- 调用方必须先通过 `AXTextInputMarkedRange`/组合状态门控，空闲时不要持续扫描；
- AX 通信应设置短消息超时，异常宿主不得阻塞监控循环。

当前验证实现设置了 `0.25s` 的单次 AX 消息超时。它不能消除多节点扫描的总耗时，
正式接入时仍应把候选读取放入有整体截止时间的异步任务，或通过通知驱动缓存失效。

### 正式链路验证

接入后使用 Safari 地址栏输入 `nihao`：

- 日志来源为 `candidate source=accessibility`；
- Debug 构建 `candidate_detect_ms=3.619625`；
- 候选稳定 120ms 后开始翻译；
- `translation_ms=109.507542`，随后正常显示 HUD；
- 候选识别期间没有触发 ScreenCaptureKit 截图。

因此当前候选识别已经切换为 AX；完整 HUD 延迟仍包含候选停留和翻译模型耗时。

### 翻译范围

“显示与触发”提供“翻译：选中 / 一栏”：

- `选中`：只翻译当前 `AXSelectedChildren`，保持原有单行 HUD；
- 实测 `AXRows` 虽被声明支持但始终为空，`AXSelectedRows` 与
  `AXElementBusy` 不支持；因此一栏模式不再依赖行 API、父链或行聚类；
- `一栏`只读取 `AXSelectedChildren` 与 `AXVisibleChildren`：可见集合包含选中项
  且数量为 2–12 时直接作为活动行，按横坐标排序并去重；否则回退到当前选中项；
- 候选列表的 `AXFrame` 可能覆盖未展开的完整候选集合。实测可见候选窗口仅
  `28pt` 高时，列表 frame 仍为 `144pt` 高，因此一栏不再用容器高度推断布局；
- 一栏按 `AXVisibleChildren` 的有效 frame 做垂直行分组：只有一个行组时使用
  该行，出现两个及以上行组时视为展开态；可见 frame 不足时回退当前选中项；
- `AXWindow` 和列表 frame 只用于确定候选栏的横向宽度与起点，HUD 的纵向锚点
  始终来自实际可见候选行；
- 全量 `AXChildren` 会膨胀到上百项，不再参与一栏候选构造，避免跨行混合和超长
  空序号 HUD；
- 一栏模式只保证单行首栏体验；可见候选形成多个行组时立即返回无候选，App
  随之取消翻译并隐藏 HUD；
- 活动行按横坐标排序后并发翻译，其他行不会进入翻译路由；
- 活动行无法通过有效 frame 确定时只回退到当前选中项，不会把整张候选表送入
  翻译；
- 多行/网格候选不会被压平成超长单行；
- 一栏 HUD 使用候选栏宽度和当前候选行高度作为固定锚点；方向键或鼠标切换候
  选时，只更新栏内高亮，不移动整个 HUD；
- 候选栏形成多个可见行组时视为展开状态并隐藏一栏 HUD；单行候选只使用可见
  候选行作为纵向锚点；
- 一栏的 candidate revision 绑定整行内容和整行位置；行内选中变化只发送
  `selectionChanged`，不会取消翻译、重新请求模型或重建 HUD；
- HUD 序号使用更小字号，选中胶囊采用更紧凑的水平与垂直内边距；
- 一栏 HUD 外层左右内边距使用 `3pt`，贴近苹果候选栏的边缘密度；选中
  胶囊内部仍保留 `5pt` 水平内边距，避免文字贴边；
- 一栏 HUD 为每个项目保留至少 44pt 的不可压缩槽位，并按同一组字体、间距和
  内边距计算自然宽度；禁止用省略号截断译文；
- 完整行超过屏幕可用宽度时，退回只显示当前选中候选的完整译文，避免压缩或
  缩小字号；
- 候选 revision 变化时旧译文先保持 80ms，随后进入 30% 淡化占位作为组合过渡；
- HUD 宽度覆盖 SwiftUI `NSHostingView` 的实际拟合宽度；槽位、字体和间距使用
  共享度量，避免短候选项触发最小宽度后挤压长译文；
- 组合会话中的候选变化立即更新 HUD frame，不重播窗口位移动画；可见期间宽度
  只增不减，避免增删词汇时反复缩放；
- 两种模式共享候选停留、revision、取消、词典/模型路由和精确缓存；
- 设置页预览直接绑定同一偏好，切换后立即在单行 HUD 与编号整栏 HUD 之间变化。

### 候选消失关闭

AX 会话结束采用立即关闭策略：

- 已有候选后首次检测到候选列表消失，立即结束候选会话；
- 组合状态从 `composing` 变为 `inactive` 时，立即结束候选会话；
- 焦点变为非文本控件或真实文字选区时，立即结束候选会话；
- `AppDelegate` 收到 immediate 结束事件后使用无动画隐藏，不再等待 60ms 淡出；
- 两帧 miss 去抖仅保留在没有活动候选会话的兼容路径。

缓存会同时保存候选窗口和候选列表。每次热路径命中前都会检查：

- 候选窗口仍属于当前应用的 `AXWindows`；
- 候选列表仍是该窗口的直接或二级子节点；
- 只有两项都成立时才读取缓存的 `AXSelectedChildren`。

Chrome 回归中，空格确认后再执行剪切/粘贴，探针从候选“你好”切换到
`candidate=<none>`，旧候选没有重新出现。`AXWindows` 查询本机 p50 约
`0.103ms`、p95 约 `0.359ms`，缓存存活校验仍处于低个位毫秒范围。

## 与 OCR 链路对比

当前 OCR 相关代码包括截图、色彩定位、候选上下文、Vision/PP-OCR、识别缓存和
运行时桥接。粗略统计以下核心文件约 2,191 行：

- `CandidateCapture`
- `OCRService`
- `FocusedCandidateLocator`
- `PPOCRRecognizer`
- `OCRResultCache`
- `OCRPluginLoader`

AX 验证实现约 320 行，其中包含通用 AX 属性读取、缓存、fallback 和诊断结构。
正式产品不需要可见候选列表诊断，代码还可以进一步缩小。

产品层面的差异更重要：

| 项目 | AX | OCR |
| --- | --- | --- |
| 候选文本来源 | 原始 AX 字符串 | 像素识别 |
| 字符保真 | 暴露后为精确文本 | 受字体、背景和模型影响 |
| 权限 | 辅助功能 | 辅助功能 + 屏幕录制 |
| 模型/插件 | 不需要 | Vision/PP-OCR 与运行时 |
| HUD 锚点 | 候选 AX frame | 蓝色高亮区域 |
| 首次发现 | 数十 ms | 截图、定位、预热模型 |
| 稳态读取 | 亚毫秒到低个位 ms | 仍经历截图和识别 |

## 风险和待验收

1. `InputMethodCandidateList` 是系统 UI 实现标识，不是 Apple 文档化稳定契约。
   API 本身是公开 AX API，但节点层级和标识需要版本兼容。
2. 当前只在 macOS 26.6.2 完成真实输入验证，macOS 14/15 尚未覆盖。
3. Safari 和 TextEdit 已通过；VS Code 曾观察到真实候选列表，但自动化键事件
   会绕过 Electron 的输入法处理，需要人工输入完成最终验收。
4. Chrome、微信、飞书、Word、多显示器、全屏和不同缩放比例尚未完成 AX 矩阵。
5. 仍需验证第三方输入法是否暴露候选列表。Glint 当前只支持 Apple 拼音，
   因此不会阻塞首版，但失败时只能静默跳过。
6. 正式接入仍保留安全输入检查、真实文字选区检查和候选停留触发。
7. 豆包等 App 的进程级焦点 fallback 本轮未实现，留待 AX 主链路稳定后的专项
   测试决定。

## 建议

当前落地状态：

1. 组合输入时从 `AXSelectedChildren` 读取候选项；
2. 使用候选 `AXTitle` 和 `AXFrame` 驱动分类、停留、HUD 位置和翻译；
3. AX 不存在时静默跳过，不因读取失败弹窗；
4. OCR 服务、插件配置和设置页完整保留，但退出当前输入识别热路径；
5. 屏幕录制权限流程暂未移除，为后续上下文能力保留；当前候选识别本身不调用
   ScreenCaptureKit；
6. 进程级焦点 fallback 暂不实现，不使用针对豆包等 App 的特例。

## 自动化验证

- `./scripts/test.sh`：全部通过，Xcode 测试为 `TEST SUCCEEDED`；
- `GlintCore` 40 个、`GlintMac` 48 个（1 个外部截图测试跳过）、
  `GlintDictionary` 6 个、`GlintInference` 10 个、`GlintPlugins` 15 个、
  `GlintUI` 22 个测试通过；
- `swift test --package-path Packages/GlintMac`：48 个测试，47 通过，1 个需要
  外部截图的测试按预期跳过；
- `./scripts/build.sh`：通过；
- Release arm64 构建：通过；
- `./scripts/run.sh`：通过 readiness token 确认唯一 Debug 实例已启动；
- 概览页显示“系统候选词”；OCR 配置页及模型管理保持可用。
