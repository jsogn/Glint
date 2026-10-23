# AX Candidate Lab

只读验证苹果拼音候选是否通过 Accessibility API 暴露，不截图、不运行 OCR。

## 构建

在仓库根目录执行：

```bash
./scripts/build.sh
```

## 跟踪当前前台 App

先启动探针，再在目标 App 中输入拼音：

```bash
GLINT_AX_PROBE_SECONDS=20 \
  ./build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint \
  --ax-candidate-probe
```

输出包含选中候选、可见候选、候选 frame、候选列表 frame 和每轮读取耗时。

## 固定测试进程

自动化环境可能无法让目标 App 保持前台，此时可指定进程：

```bash
GLINT_AX_PROBE_PID=12345 \
GLINT_AX_PROBE_SECONDS=20 \
  ./build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint \
  --ax-candidate-probe
```

`fixture.html` 可用于 Safari 或 Chromium 的文本框验证。

## 解释

- 候选列表来自当前宿主 App 的 AX 窗口树。
- 查找标识为 `InputMethodCandidateList` 的 `AXList`。
- 选中项来自列表的 `AXSelectedChildren`。
- 候选文本通常位于 `AXTitle`，不是 `AXSelected` 或 `AXValue`。
- 探针只读取候选列表子树，不读取输入框正文。

键盘自动化可能绕过 Electron/Chromium 的输入法处理，因此自动化无法生成候选
不等于真实用户输入无法生成候选。这类宿主仍需人工输入验收。

## 枚举候选原始属性

`CandidateAXProbe` 只读取候选列表子树，并输出
`InputMethodCandidateList`、选中项和可见候选项的全部 AX attribute/value：

```bash
swift build --package-path Tools/GlintEval --product CandidateAXProbe
Tools/GlintEval/.build/debug/CandidateAXProbe --pid <目标 App PID>
```

运行前让目标 App 保持 Apple Pinyin 候选栏可见，例如输入 `jieguo` 并停留在
`结果`。该探针不会读取输入框正文。

2026-10-22 实测结果：候选只暴露 `AXTitle`、`AXDescription`、
`AXValueDescription`、`AXRoleDescription` 等文本字段，没有拼音或读音字段。
`AXRoleDescription` 是“结构的结，如果的果”这类汉字说明。因此当前 AX
接口不能满足拼音消歧；当前候选兼容边界见
`docs/AX-CANDIDATE-VALIDATION.md`。

## 微信输入法结构探针

`WeTypeAXProbe` 从 `WeType` 独立进程读取候选窗口，不依赖宿主 App 的
`InputMethodCandidateList`。探针默认只输出角色、属性名、文本长度、选择状态和
frame，不输出候选原文。

先让微信输入法候选栏保持显示，再执行：

```bash
swift build --package-path Tools/GlintEval --product WeTypeAXProbe
Tools/GlintEval/.build/debug/WeTypeAXProbe --seconds 20
```

固定进程调试可使用：

```bash
Tools/GlintEval/.build/debug/WeTypeAXProbe --pid <WeType PID>
```

重点查看 `selectedSemanticsAvailable` 和
`styleSelectedCandidateIndex`。当前微信输入法没有原生选中节点，但候选数字和
文字的 `AXForegroundColor` 会随高亮切换；探针根据唯一更亮的数字组推导索引。
完整实验记录见 `docs/WETYPE-AX-RESEARCH.md`。
