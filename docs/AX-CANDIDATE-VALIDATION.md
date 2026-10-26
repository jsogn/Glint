# Glint AX Candidate Validation

- 状态：现行
- 最近校准：2026-10-26
- 验证环境：Apple M4 Pro、48GB、macOS 26.6.2（25G83）

本文记录 Glint 使用的公开 Accessibility 候选结构、兼容边界和验证证据。通用
Profile、缓存和资源上限见
[未知输入法通用适配](GENERIC-INPUT-METHOD-ADAPTATION.md)。

## 结论

Glint 通过 Accessibility 读取当前输入法候选，不使用截图、OCR 或键盘监听。
该方案可覆盖宿主 App 标准候选、独立输入法进程和不同候选实现，但 AX 节点层级
不属于 Apple 文档化稳定契约，输入法升级后仍需回归。

| 结构 | 高亮来源 | 使用方 |
| --- | --- | --- |
| 宿主 `InputMethodCandidateList` | 父列表 `AXSelectedChildren` | Apple 拼音 |
| 独立分组文本项 | 候选项容器 `AXSelected` | 通用 Profile |
| 独立文字样式 | 唯一高亮数字组的前景亮度 | 微信显式 reader |
| 独立匿名 `AXList` | 无高亮语义，首候选降级 | 搜狗显式 reader |

候选运行态统一接受单行 `1...9` 项。展开为多行或网格时立即隐藏 HUD；收起后
重新发现候选，不将临时布局计为结构失配。

## 已确认结构

### Apple 拼音

候选位于宿主 App 的 AX 窗口树，而不是只在 `SCIM_Extension` 进程中：

```text
TextEdit AXWindow / AXDialog
└─ AXList  AXIdentifier = InputMethodCandidateList
   ├─ AXButton  AXTitle = 你   ← AXSelectedChildren
   ├─ AXButton  AXTitle = 尼
   ├─ AXButton  AXTitle = 泥
   └─ ...
```

- 候选文字通常位于 `AXTitle`，`AXValue` 为空。
- 候选自身的 `AXSelected` 不可用于判断高亮。
- 当前候选由父列表的 `AXSelectedChildren` 给出。
- 候选 `AXFrame` 提供屏幕位置；方向键切换后 frame 同步移动。
- 组合结束后候选列表消失。Escape、提交、失焦和切换输入源均会结束会话。

TextEdit、Safari 和 Chrome 已完成代表性验证。Electron/Chromium 的自动化键盘
事件可能绕过输入法，不能以自动化未出现候选推断真实输入失败。

### 独立输入法进程

- 微信候选由独立 `AXWindow` 暴露，没有原生 `AXSelected`。数字和文字的前景亮度
  随高亮变化，唯一更亮的数字组用于定位当前候选；无法判断时退回首候选。
- 搜狗候选位于匿名 `AXList`，文字和 frame 可读取，但没有可用的当前高亮语义。
  默认选中模式使用首候选并返回 `selectionIsExact=false`，不伪造高亮。
- 豆包使用“候选项容器 + 数字序号 + 文字”结构，容器自身提供 `AXSelected`；
  容器 frame 用于候选定位，内部文字 frame 不作为选中依据。
- 独立候选窗口和匿名列表只从当前 TIS 输入源对应的输入法进程读取，不扫描普通
  宿主 App 的 `AXList`。

## 运行规则

- 只有组合输入状态允许探测未知候选结构；首次成功探测所在组合只采样，下一次
  组合启用已验证 Profile。
- 未知输入法的展示能力为 best-effort；首次使用可能暂时没有译文。
- 候选变化时恢复 `40ms` 轮询；候选达到停留条件并启动翻译后降至 `80ms`。
- 候选重新变化时立即恢复 `40ms`，不增加翻译后的固定等待。
- 组合结束、窗口消失或确认的多行布局一次检测即关闭 HUD。
- AX timeout、瞬时空值等不确定失败使用两帧去抖，避免 HUD 闪烁。
- Profile 连续结构失配至少 3 次且持续 2 秒才失效；瞬时读取失败不会删除 Profile。
- 只读取候选文本、frame、角色和选中语义；不读取输入框正文或真实选中文字。
- 密码框、Secure Input 和真实文字选区在使用候选读取前跳过。

`AXReadSession` 为所有 reader 设置单次消息超时、属性调用上限和总截止时间。
交互读取最多 `192` 次调用、`300ms`；后台探测每个结构最多 `64` 次调用、
`150ms`。同步 AX 请求本身不能被中断，因此这些限制约束的是后续调用，而不是
已经发出的单次请求。

## 性能与稳定性

以下数据用于识别数量级，不作为所有设备或版本的固定 SLA。

| 场景 | 结果 |
| --- | --- |
| Apple 热路径，Release | p50 `0.37–0.40ms`，p95 `1.15–1.76ms` |
| Apple 首次发现 | 约 `35–94ms` |
| Apple 无候选扫描 | 约 `12–24ms` |
| 豆包冷读取 | 约 `45.7–47.9ms` |
| 豆包热读取，选中 | p50 `4.156ms`，p95 `13.159ms` |
| 豆包热读取，整行 | p50 `4.428ms`，p95 `8.106ms` |
| 稳定候选 CPU | Glint 约 `1.3%`，豆包约 `1.2%` |

AX 调用偶发出现数百毫秒长尾，极端样本曾超过 3 秒，因此不能将 AX 读取描述为
始终零延迟。组合状态门控、单次消息超时、总读取预算和低频稳定轮询用于控制影响。

2026-10-26 豆包异常注入验证：

- 候选显示期间暂停输入法 1 秒，恢复后读取与 HUD 更新正常。
- 终止输入法后旧 HUD 关闭；服务以新 PID 重启后约 `9.2ms` 恢复读取。
- 展开为 6 行、35 个子项时旧 HUD 立即隐藏；收起后恢复翻译。
- 设置页将候选停留从 `80ms` 改为 `300ms` 后实测约 `312ms`，恢复后约 `94ms`，
  确认偏好实时进入运行链路。

## 已验证范围

- Apple 拼音：TextEdit、Safari、Chrome 的候选、方向键和组合结束。
- 豆包输入法 1.0.2：TextEdit、Safari、Chrome、候选展开/收起和进程重启。
- 微信输入法：用户完成宿主人工键入验收。
- 搜狗拼音：独立匿名候选列表的文字和位置读取；无高亮项时按能力降级。
- 候选会话支持 Escape、提交、失焦、输入源切换和多行展开关闭。
- 2026-10-26 发布快照：GlintMac 124 项测试、完整 `./scripts/test.sh`、
  Debug/Release arm64 构建和单实例 readiness 启动均通过。

## 已知边界

- `InputMethodCandidateList` 和输入法内部 AX 结构都可能随系统或输入法升级变化。
- VS Code 仍需人工输入完成完整验收；飞书、Word、多显示器、全屏和不同缩放比例
  尚未形成完整矩阵。
- 第三方输入法皮肤可能增加透明或装饰区域。搜狗默认皮肤固定保留上下 `8pt`
  透明边距，其他皮肤由用户 HUD 间距兜底。
- 飞书和部分 Chromium/Electron App 的 `AXEnhancedUserInterface` 状态会影响
  可见 AX 树。写入后必须回读；返回值 `-25208` 不能单独作为失败结论。
- 宿主进程状态使用“PID + Bundle ID + 启动时间 + 可执行路径”识别，避免 PID
  复用后继承旧缓存。
- 分组文本项缓存热路径验证进程会话、窗口归属、父链、子节点数量和候选项身份；
  任意不一致时重新发现，不使用无验证的长期节点缓存。

验证工具的构建和运行方式见
[Tools/AXCandidateLab/README.md](../Tools/AXCandidateLab/README.md)。
