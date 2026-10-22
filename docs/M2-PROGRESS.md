# Glint M2 Progress

- 日期：2026-10-19
- 状态：进行中
- 关联 PRD：`docs/PRD-v0.3.md`
- 关联 M1：`docs/M1-MODEL-SPIKE.md`

## 已完成

### 1. 路由

- `SmartRouter` 已按 M1 结论调整：
  - 单词/短语：只走词典；
  - 短句：走翻译引擎；
  - 单词未命中/歧义：不显示。
- 纯模型模式仍保留，但不再作为默认路径。

### 2. 词典

- 已生成只读 SQLite：`Resources/Dictionary/cedict.sqlite3`（183,662 条）；
- 已加入 98 条业务/技术 override；
- 已加入 `打 / 尼 / 你号` 等歧义 blocklist（M20 已只保留 `你号`）；
- `CedictDictionary` 已从内存占位改为 SQLite 查询；
- CLI 验证：

```text
你好 -> hello
算法 -> algorithm
计算 -> calculate
复盘 -> retrospective
中国 -> China
苹果 -> apple
打 -> <not found>
```

### 2.1 ECDICT 排序/兜底

- 从 ECDICT 构建了紧凑排序索引：
  - 101,755 个中文词项；
  - 152,449 条“中文 → 英文头词”候选；
  - 约 12.3MB；
- 插件 ID：`dict-ecdict`，许可证 MIT；
- 作用：
  - CEDICT 有词条时保留 CEDICT 的义项顺序；
  - CEDICT 未命中时，用 ECDICT 高频头词兜底；
  - 不盲目用 ECDICT 词频覆盖 CEDICT，因为会出现“设计 → plan”“开发 → exploit”这类义项错误。

`DictionaryRouter` 已接入：

```text
dict-cedict (priority 0)
  → dict-ecdict (priority 1)
  → 不显示
```

验证：

```text
计算机 -> computer
程序 -> program
开发 -> develop
设计 -> design
数据 -> data
内卷 -> involution
躺平 -> <not found>
```

### 3. 截取/OCR

- `GlintMac/CandidateCapture` 已迁入 ScreenCaptureKit；
- `GlintMac/OCRService` 已迁入 Vision + 蓝色胶囊检测；
- `GlintMac/FocusMonitor` 已迁入 Accessibility 光标/控件 frame；
- `GlintMac/MonitoringController` 已串起 TIS → AX → 截取 → OCR → SmartRouter。

### 4. App

- App 启动后显示主窗口；
- 菜单栏提供开始/停止监控；
- HUD 可显示词典结果；
- 权限缺失时提供系统权限提示；
- `BUILD SUCCEEDED`；
- App + 5 个 Package 测试全部通过。

### 5. CTranslate2 / OPUS 接入

已完成：

- 使用 CTranslate2 源码 headers + Python wheel 的 `libctranslate2` dylib；
- 从源码构建 SentencePiece shared library；
- 实现 `Bridges/CTranslate2Bridge` C ABI：
  - `glint_ct2_create`
  - `glint_ct2_translate`
  - `glint_ct2_free_string`
  - `glint_ct2_destroy`
- `GlintInference/CTranslate2Engine` 通过 `dlopen` 加载 bridge；
- 本地 App bundle 已放入 OPUS CT2 模型和 dylib；
- CLI 验证：

```text
今天天气不错 -> It's a nice day.
```

注意：当前模型/dylib 是本地开发资源，正式版仍由插件管理器下载；App bundle 目前约 98MB，不代表最终安装包。

### 6. 插件管理

已完成：

- `PluginManager` 扫描 `~/Library/Application Support/Glint/plugins`；
- 支持本地插件安装、删除、插件目录解析；
- 开发安装脚本：

```bash
./scripts/install_dev_plugins.sh
```

- 已安装 `dict-cedict`、`dict-ecdict` 和 `opus-ct2-int8`；
- `CedictDictionary` / `CTranslate2Engine` 优先读取 Application Support 插件；
- 主窗口「插件与模型」页读取真实安装状态；
- `run.sh` 会自动安装开发插件。

## 仍待完成

### 1. 翻译插件管理

- Qwen3-4B MLX 适配器；
- 远程模型下载、SHA256、zip 安装；
- 模型加载失败时的降级。
- 正式版把 CT2 模型/dylib 从 App bundle 移到下载插件。

Qwen 备注：官方 `mlx-swift-lm 3.32.3` 已支持 Qwen3，但接入会引入 MLX、
swift-syntax 和 tokenizer loader 依赖，需要单独做一次 MLX Swift spike；
本轮没有把这条大依赖塞进主工程。

### 2. 主窗口

- “开始监控”按钮与 AppDelegate 动作打通；
- 插件与模型页接真实下载状态；
- 权限页接真实 TCC 状态和截取范围预览。

### 3. 端到端验证

- TextEdit + 苹果拼音真实输入；
- 不同 App/光标位置/多屏；
- 单词、短语、短句、歧义和 skip 用例。

## 下一步建议

- 用真实 TextEdit + 苹果拼音跑一次端到端 HUD；
- 把模型/dylib 从 bundle 移到 `Application Support` 插件目录；
- 接 Qwen3-4B MLX 作为可选高质量插件；
- 再做主窗口的下载状态和权限引导。
