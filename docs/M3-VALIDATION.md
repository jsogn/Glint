# Glint M3 Validation

- 日期：2026-10-19
- 机器：MacBook Pro，Apple M4 Pro，48GB，macOS 26.6.2
- App：开发版 Debug 构建
- 目标：验证真实输入链路，而不是继续加功能

## 1. 自动化验证

### 构建与测试

- `BUILD SUCCEEDED`
- `TEST SUCCEEDED`
- App + GlintCore / GlintMac / GlintDictionary / GlintInference / GlintPlugins 测试通过

### GUI 启动回归

首次运行 `./scripts/run.sh` 时，App 在自动开始监控后闪退。

崩溃栈：

```text
dispatch_assert_queue_fail
TSMGetInputSourceProperty
InputSourceMonitor.currentInputSourceID()
InputSourceMonitor.isApplePinyinActive()
MonitoringController.tick()
MonitoringController.run()
```

根因：

- Carbon TIS/TSM 的 `TSMGetInputSourceProperty` 要求在主线程调用；
- `MonitoringController` 是 actor，原实现在协作线程查询输入源；
- `--selfcheck` 不启动监控，因此此前没有暴露该问题。

修复：

- 将 `InputSourceMonitor.currentInputSourceID()` 和 `isApplePinyinActive()` 标记为 `@MainActor`；
- `MonitoringController.tick()` 通过 `await` 回到主线程查询；
- 对应单元测试改为主线程异步测试。

验证结果：

- `./scripts/build.sh`：通过；
- `./scripts/test.sh`：全部通过；
- `./scripts/run.sh`：App 启动后连续存活 10 秒，进程未退出；
- 修复后没有新增 Glint 崩溃报告。

### 翻译显示开关与权限引导

问题：

- 主窗口的“开启翻译显示”按钮绑定的是空闭包，因此点击没有反应；
- 菜单栏命令和主窗口按钮没有共享监控状态；
- 权限页始终显示“待授权”，没有读取真实 TCC 状态；
- 辅助功能缺失时，权限弹窗仍然打开屏幕录制设置。

修复：

- 增加 `MainWindowModel`，统一主窗口的监控状态、权限状态和操作入口；
- “开启翻译显示”和“关闭翻译显示”复用菜单栏的同一套控制逻辑；
- 权限页读取真实的屏幕录制、辅助功能授权状态；
- 权限弹窗根据缺失项打开对应的系统设置页；
- `run.sh` 在重新构建前关闭旧进程，避免继续打开旧实例。

界面验证：

- “关闭翻译显示” → 状态“未开启”、按钮“开启翻译显示”；
- “开启翻译显示” → 状态“已开启”、按钮“关闭翻译显示”；
- 权限页显示“屏幕录制：已授权”“辅助功能：已授权”。

当前开发机两项权限均已授权，因此点击开始会直接进入监控；只有权限缺失时才会显示系统授权提示和应用内引导。

### 菜单栏监控标识

- 未监控：菜单栏显示 `✦`；
- 翻译显示开启：`✦` 右侧显示一个 5pt 左右的系统黄色圆点；
- 辅助功能描述同步为“Glint，翻译显示已关闭”或“Glint，翻译显示已开启”；
- 菜单栏提示文字同步显示当前状态。
- 菜单中只保留一个动态动作：未开启时显示“开启翻译显示”，开启后显示“关闭翻译显示”。

已实际截图确认暂停、开启两种状态，黄色圆点只在翻译显示开启时显示。

### 候选栏截取范围回归

现象：重新构建并开启翻译显示后，在 TextEdit 输入拼音时不再出现 HUD。

运行日志停在：

```text
Glint: 未检测到高亮候选
```

根因：

- 苹果输入法候选栏会根据窗口位置显示在光标上方或下方；
- 原实现固定截取光标下方 150pt，TextEdit 位于屏幕上方时候选栏在光标上方，被完全裁掉；
- 输入源、辅助功能、ScreenCaptureKit 和 OCR 实际都已正常工作。

修复：

- 截取区域改为围绕光标上下共 180pt 的带状范围；
- 增加“候选栏位于光标上方和下方都能覆盖”的回归测试。
- ScreenCaptureKit 排除 Glint 自己的窗口，避免主窗口按钮或 HUD 被 OCR 误判为候选栏。

### App 自检

命令：

```bash
./build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint --selfcheck
```

结果：

```text
screenRecording=true
accessibility=true
dict 你好 -> hello
dict 算法 -> algorithm
dict 程序 -> program
dict 设计 -> design
dict 内卷 -> involution
ct2 今天天气不错 -> It's a nice day.
ocr candidate=你好 confidence=1.0
ocr dictionary=hello
```

这证明：

- ScreenCaptureKit / Accessibility 权限在 App bundle 上可用；
- 词典路由可用；
- OPUS CTranslate2 可用；
- Vision OCR + 蓝色胶囊检测可用；
- 示例候选栏能得到“你好”。

## 2. 真实 TextEdit 验证

尝试了 TextEdit + 苹果拼音 `nihao`。

结果：**阻塞于当前自动化环境的前台覆盖层**。

现象：

```text
frontmost = ChatGPT
AX focused element error = -25204
TextEdit 内容 = ni hao
Input Source = com.apple.inputmethod.SCIM.ITABC
```

`-25204` 表示辅助功能无法从当前前台取得焦点元素。由于 Codex/ChatGPT 覆盖层占住前台，TextEdit 虽然收到了输入，但 Glint 读不到它的焦点控件，因此不会显示 HUD。

这不是 OCR、词典或 OPUS 链路失败；是测试环境的焦点问题。

另外，测试中发现：

- Input Source Pro 会按 App 把 TextEdit 切回 ABC；
- 为了完成拼音输入测试，临时退出 Input Source Pro 后，TextEdit 的输入源可以保持 Pinyin；
- 测试结束后已重新启动 Input Source Pro，并恢复 ABC。

## 3. 兼容性矩阵

| App | 状态 | 备注 |
|---|---|---|
| TextEdit | 阻塞 | 前台被 ChatGPT/Codex 覆盖层占用，AX 无焦点 |
| Safari | 待测 | 需要真实用户会话 |
| Chrome | 待测 | 需要真实用户会话 |
| VS Code | 待测 | 需要真实用户会话 |
| 微信 | 待测 | 需要真实用户会话 |
| Word | 待测 | 需要真实用户会话 |
| 密码框/安全输入 | 待测 | 应完全不显示 |

## 4. 手动验收步骤

在不受 Codex/ChatGPT 覆盖层影响的前台会话中：

```bash
cd /Users/alone/code/Glint
./scripts/run.sh
```

然后：

1. 打开 TextEdit，切换到苹果拼音；
2. 输入 `nihao`；
3. 观察蓝色高亮的“你好”旁是否出现 `hello`；
4. 输入 `suanfa`，应显示 `algorithm`；
5. 输入 `jintiantianqibucuo`，应由 OPUS 显示短句翻译；
6. 输入单字 `打`，应不显示；
7. 在密码框中输入，应不显示；
8. 关闭 Glint 主窗口，确认菜单栏监控仍在。

## 5. 当前已知限制

- 开发版模型/dylib 仍在 bundle 与插件目录之间共存，正式版需要只保留插件目录；
- 插件管理器目前是本地安装，没有远程下载/zip 安装；
- Qwen3-4B MLX 尚未接入；
- 词典优先级固定为 `dict-cedict → dict-ecdict`，还没有拖拽排序 UI；
- 真实 App 兼容性测试需要干净前台会话。

## 6. 下一步

1. 在干净会话完成 TextEdit/Safari/Chrome/VS Code/微信矩阵；
2. 根据失败矩阵修候选窗定位和 AX 兼容；
3. 再做主窗口开始/停止、插件状态、权限状态；
4. 最后接 Qwen3-4B MLX。
