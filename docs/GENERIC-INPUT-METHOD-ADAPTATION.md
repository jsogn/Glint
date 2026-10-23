# 未知输入法通用适配

## 结论

Glint 对外提供三种候选读取能力：

- 宿主 App 中具有 `InputMethodCandidateList` 语义的标准候选列表；
- 独立输入法进程中的单行 `AXList + AXStaticText` 候选结构；
- 独立候选窗口中的直接 `AXStaticText` 候选结构，可结合原生选中语义或
  `AXForegroundColor` 判断高亮。

苹果拼音、微信和搜狗继续使用各自的显式 reader。未知第三方输入法只有在后台探测
并验证上述结构后，才启用对应的通用 Profile。

## 安全边界

- 不扫描普通宿主 App 的 `AXList`，避免把侧栏、列表或任务列表误认为候选栏。
- 只检查当前 TIS 输入源对应的输入法进程，不遍历其他 App。
- 不监听键盘，不截图，不执行 OCR，不调用输入法私有接口。
- 探测日志只记录输入源 ID、Profile 类型、耗时和尝试次数，不记录候选原文。

## 探测流程

1. 未知输入法先使用标准 reader 读取宿主 App。
2. 只有 `AXTextInputMarkedRange` 表明正在组合输入时，标准 reader 失配才会触发
   探测；空闲编辑状态不会提前消耗探测机会。
3. 当前轮询立即结束，后台低优先级任务对当前输入法 bundle 执行一次有节点上限的
   结构探测。
4. 匹配 Profile 后按输入源 ID 和 bundle 缓存，后续组合直接使用通用 reader。
5. 成功 Profile 同时写入 `UserDefaults`，并使用输入法版本参与缓存键。Glint
   重启或输入法服务重启后继续复用；输入法版本变化时旧 Profile 自动失配。
6. Profile 只保存 bundle、输入源 ID、应用版本和结构枚举，不保存候选文本；
   失败结果、错误和冷却时间不落盘。
7. 不兼容结果不会每次组合重试。第一次失败后等待 `500ms` 再尝试一次；之后按
   `10 / 20 / 40 / 60` 分钟指数退避。
8. 全局同一时间只允许一个 Profile 探测任务，防止进程崩溃重启造成扫描风暴。

未知输入法首次使用可能暂时没有翻译。这是明确接受的 best-effort 边界；只有探测
完成后才会在当前运行中启用通用支持。

## AX 资源上限

- 常规独立进程 reader 最多检查 3 个窗口。
- 搜狗形态每次最多检查 24 个直接节点；微信形态最多检查 36 个直接节点。
- 后台 Profile 探测最多检查 2 个窗口、16 个节点，单次 AX 消息超时为 `50ms`。
- 候选行最多 9 项，多行、空 frame 或结构冲突时直接拒绝。
- 后台确认单行列表 Profile 时至少需要 2 个候选；直接文字 Profile 还要求存在唯一、
  可验证的样式高亮，避免把输入法设置窗口中的普通文字误判为候选栏。

这些限制不能中断已经发出的同步 AX 消息，但能限制总节点数，并确保探测不在候选
读取主路径上执行。

## 故障行为

- 输入法缺失、AX 属性异常、窗口消失或类型不匹配时均返回无候选。
- 候选读取失败不启动翻译模型，不弹运行时错误。
- Profile 读取失败时先尝试标准 reader，不会因此关闭监控。
- TIS 数据缺少 bundle ID 时不进行通用探测，只保留标准候选路径。

## Profile 验证工具

`CandidateProfileProbe` 绕过显式输入法注册，直接对指定 Bundle 运行通用探测器，
用于验证搜狗、微信和未知输入法是否匹配 Profile。工具只输出 Bundle、输入源、
Profile 名称和耗时，不输出候选原文。

在文本编辑器中保持候选栏显示时运行：

```bash
swift run --package-path Tools/GlintEval CandidateProfileProbe \
  --bundle com.sogou.inputmethod.sogou \
  --source com.sogou.inputmethod.sogou.pinyin \
  --seconds 30
```

```bash
swift run --package-path Tools/GlintEval CandidateProfileProbe \
  --bundle com.tencent.inputmethod.wetype \
  --source com.tencent.inputmethod.wetype.pinyin \
  --seconds 30
```

预期结果分别为 `isolatedCandidateList` 和 `isolatedStyledText`；没有候选或结构
不满足约束时输出 `profile.matched=none`。
