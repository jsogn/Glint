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
