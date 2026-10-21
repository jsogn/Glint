# Glint M12 Typing-Aware Pipeline Validation

- 日期：2026-10-21
- 目标：验证候选停留触发、翻译任务解耦、精确结果缓存和权限检查节流

## 实现结果

- `TypingActivityTracker` 负责候选 revision、连续帧确认和高亮几何稳定性。
- `TranslationMemo` 提供精确匹配、内存 LRU、容量/成本上限和并发请求合并。
- `MonitoringController` 在候选停留后才启动词典/模型，并持续进行 OCR 观察。
- 新候选到达时保留 HUD 外壳、取消旧任务、将旧译文降为淡化占位，并通过 revision 丢弃迟到结果。
- `AppDelegate` 已移除翻译完成后的固定 HUD 等待。
- “显示延迟”改为“候选停留”，使用新键 `display.candidateDwellDuration`，表示候选稳定多久后触发翻译。
- 候选停留使用新键 `display.candidateDwellDuration`，默认 120ms，范围 80–300ms；开发阶段不读取旧键。
- 权限状态检查从每个轮询周期降为最多每秒一次。
- 通过 `AXSelectedTextRange` 与 `AXTextInputMarkedRange` 排除真实文字选区，同时保留拼音组合输入。
- HUD 复用持久 `NSPanel`/`NSHostingView`，使用淡入、淡出、原位文字交叉淡化和动画代次。
- 候选会话只有在连续两帧未检测到候选后才结束，单次 OCR 漏检不会闪退 HUD。
- 已确认进入组合后，如果 `AXTextInputMarkedRange` 明确结束且该轮没有候选，HUD 立即进入 60ms 淡出，不再等待第二帧 OCR。
- 候选变化后旧译文先保持 80ms；快速结果直接替换，超过 80ms 才淡化并持续显示占位，不出现空白 HUD。
- 候选组合会话中 HUD 的 frame 立即跟随候选栏，不使用 90ms 位移动画；可见期间
  面板宽度只增不减，避免增删拼音或词汇时反复缩放抖动。
- Reduce Motion 下不执行亮度渐变，80ms 后直接切换到淡化占位。
- 截屏前增加焦点扫描门控：组合状态直接允许；非组合或未知状态要求可编辑文本角色、`AXEditable` 或真实光标之一。
- 菜单项、按钮和普通消息容器不会被接受为候选扫描目标，避免把蓝色徽章识别成输入法候选。

## 自动化验证

完整执行：

```text
./scripts/test.sh
```

结果：

- Xcode App 测试通过。
- Release arm64 App 构建通过；验证产物已从 LaunchServices 注销并清理。
- `GlintCore`：40 个测试通过。
- `GlintMac`：20 个测试通过。
- `GlintDictionary`：6 个测试通过。
- `GlintInference`：8 个测试通过。
- `GlintPlugins`：10 个测试通过。
- `GlintUI`：7 个测试通过。

新增覆盖：

- 每 50ms 变化一次的候选在连续 40 次采样中不会进入停留状态。
- 同一候选满足连续采样和时间阈值后只触发一次停留。
- 高亮位置变化会创建新 revision。
- 缓存按配置版本隔离，相同请求会合并，LRU 淘汰有效。
- 候选停留默认值、范围夹取和变更通知有效。
- TextEdit 拼音组合返回 `AXSelectedTextRange = (6, 5)`、`AXTextInputMarkedRange = (6, 5)`，不会被误判为文字选区。
- TextEdit 真实文本选区返回 `AXSelectedTextRange = (1, 6)`，会正确跳过。
- 单帧 OCR 漏检被去抖；AX 主链路中已有候选后首次缺失即立即结束会话。
- 组合范围从 `composing` 变为 `inactive` 后，有组合证据的候选会话会立即结束；没有组合证据时，AX 候选会话首次缺失即结束。
- `AXTextField`、`AXTextArea` 和 `AXEditable` 元素允许在未知组合状态下扫描；菜单项始终拒绝。

## 当前性能基线

- 词典回归：130/130 top-1，p95 约 1.36ms。
- PP-OCRv6 small：精确匹配 99.75%，完整 Swift 链路 p95 约 11.82ms。
- 权限 TCC IPC：旧运行进程观察到每轮约多次请求；节流后实测约每秒一次。
- 空闲运行时：抽样 CPU 约 0–1%，RSS 约 1.25GB，包含已加载的 Hy-MT2。

OCR 性能结论来自当前机器上的原生测试，不用于产品文案中的固定速度承诺。

## 真实运行检查

- 最新 Debug App 经 `./scripts/run.sh` 启动并保持运行。
- “显示与触发”页实际显示“位置与触发”“候选停留”和新的触发说明。
- 新版实际显示候选停留 120ms，旧的 `display.stabilityDelay` 不再读取。
- 权限日志中的高频 TCC 请求已显著下降。

## 待人工验收

自动化键盘注入会绕过 macOS 输入法组合候选链路，无法可靠生成真实苹果拼音候选。
因此仍需用户实际输入以下场景：

1. 快速连续输入时 HUD 不出现、不闪烁，模型不被反复调用。
2. 停止输入后 HUD 快速出现一次。
3. 同一组合中继续输入时 HUD 不关闭，只淡化旧译文；提交后才隐藏。
4. 再次输入相同候选时缓存命中。
5. 多行输入框中上下相邻候选不会串用旧结果。
