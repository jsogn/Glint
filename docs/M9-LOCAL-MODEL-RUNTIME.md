# Glint M9 Local Model Runtime

- 日期：2026-10-20
- 目标：让用户在设置中真实安装、选择并运行多档本地翻译模型

## 1. 结论

生产路径分为三类：

1. **CTranslate2**：OPUS-MT 中英 int8，77–79MB，低延迟、低内存；
2. **专用翻译 MLX**：Hy-MT2 1.8B、Index-Translate 2B；
3. **通用多语言 MLX**：Qwen3 0.6B / 1.7B / 4B，保留用于后续多语言扩展。

路由提供两个优先级模式，首选来源无结果或失败时都回退另一来源：

```text
词典优先：词典 → 未命中/失败 → 当前翻译模型
模型优先：当前翻译模型 → 无结果/失败 → 词典
```

单词、短语和句子不再因为分类结果而跳过模型。分类器只用于理解候选形态和后续排序，不作为“是否允许模型兜底”的门槛。

## 2. 实际技术栈

| 层 | 技术 |
|---|---|
| App shell | Swift 6、AppKit、SwiftUI |
| 候选与上下文 | Accessibility |
| 轻量翻译 | CTranslate2 C ABI + OPUS-MT int8 |
| LLM 推理 | MLX Swift 3.32.3 / mlx-swift 0.32.3 |
| Tokenizer | swift-transformers 1.3.5，本地目录加载 |
| 插件安装 | Hugging Face snapshot API + pinned revision + LFS SHA-256 |

App 不在翻译时联网。模型下载只发生在用户点击“安装”时；完成下载后，所有权重都从
`~/Library/Application Support/Glint/plugins/<model-id>/model` 读取。

## 3. 模型与实测

测试机器：Apple M4 Pro，48GB，macOS 26.6.2。

| 模型 | 下载体积 | p50 | p95 | RSS/峰值 | 定位 |
|---|---:|---:|---:|---:|---|
| OPUS-MT CT2 int8 | 77–79MB | 18.7ms | 41.2ms | 约 256MB | 最低延迟 |
| **Hy-MT2 1.8B 4-bit** | **1.02GB** | **49.0ms** | **77.5ms** | **约 1.45GB** | **专用翻译，推荐** |
| Index-Translate 2B 4-bit | 1.08GB | 53.5ms | 98.4ms | 约 1.63GB | 专用翻译，质量备选 |
| Qwen3 0.6B 4-bit | 351MB | 49.8ms | 66.0ms | 约 876MB | 低内存 |
| Qwen3 1.7B 4-bit | 984MB | 141.5ms | 190.3ms | 约 1.47GB | 通用多语言保留档 |
| Qwen3 4B 4-bit | 2.28GB | 166.6ms | 218.9ms | 约 2.7GB | 高质量 |

Qwen3 0.6B 在复杂句中会漏主语或截断语义，因此只作为低内存档，不作为默认推荐。
Hy-MT2 1.8B 只比 Qwen3 1.7B 大约 34MB，但实测 p50 从 141ms 降到 49ms，短句自然度也更好。
Index-Translate 2B 在严格命中上与 Qwen3 4B 持平，但速度和体积明显更优。

代表输出：

| 输入 | Hy-MT2 1.8B | Index-Translate 2B |
|---|---|---|
| 我先看一下 | Let me take a look first. | Let me take a look first. |
| 这个方案需要再讨论 | This proposal needs further discussion. | This solution needs further discussion. |
| 这个功能什么时候上线 | When will this feature be launched? | When will this feature be launched? |
| 我晚点回复你 | I will get back to you later. | I'll reply to you later. |

## 4. MLX 运行时实现

- `MLXTranslationEngine` 是 actor，串行管理模型加载和推理；
- 一个 `ModelContainer` 常驻，不为每个候选重新加载权重；
- 每次翻译创建独立 `ChatSession`，避免上一条输入污染下一条；
- Qwen3 使用通用 system instruction，并通过 `additionalContext` 关闭 thinking；
- Hy-MT2 与 Index-Translate 使用各自的用户级翻译指令，不套用 Qwen 的 system prompt；
- 所有模型都要求单行英文翻译，不解释、不引用、不输出中文；
- 输出清理会移除 `<think>`、标签、引号和“Translation:”前缀；
- 模型不可用时自动回退到 OPUS-MT，不阻塞用户输入。

不再依赖 `MLXHuggingFace` 宏。项目内显式实现 `TokenizerLoader`，避免 Xcode
宏信任校验，也让本地模型加载路径更直接。

## 5. 安装与校验

MLX 模型在插件页点击安装后：

1. 从 pinned revision 请求 Hugging Face snapshot 文件清单；
2. 过滤权重、tokenizer、config 和 chat template；
3. 预估磁盘空间，空间不足时拒绝安装；
4. 逐文件下载；
5. 校验文件大小；
6. 校验 LFS 文件的 SHA-256；
7. 在临时目录组装 `manifest.json + model/`；
8. 完整成功后才替换现有插件。

0.6B 快照安装冒烟测试已通过，LFS 校验和目录结构均正确。

## 6. 构建要求

Xcode 26 需要额外安装 Metal Toolchain：

```bash
xcodebuild -downloadComponent MetalToolchain
```

随后：

```bash
./scripts/run.sh
build/Build/Products/Debug/Glint.app/Contents/MacOS/Glint --selfcheck
```

自检已在真实 `.app` 进程中输出：

```text
mlx[mt-hy-mt2-1.8b] 这个功能什么时候上线
  -> When will this feature be launched?

mlx[mt-index-translate-2b] 这个功能什么时候上线
  -> When will this feature be launched?
```

## 7. 当前限制

- 模型选择切换后的首次推理需要模型加载时间；App 启动时会预热当前模型；
- K/V cache 和上下文排序尚未用于区分同一中文词的多个英文义项；
- 候选栏识别依赖 Apple 拼音暴露的 `InputMethodCandidateList` AX 结构；
- 真实 TextEdit HUD 测试需要目标 App 使用苹果拼音输入源；
- 模型插件尚未做独立签名清单，当前依赖 HTTPS、pinned revision 和 LFS SHA。
- Index-Translate 当前使用社区 MLX 4-bit 转换；正式发行前应改为项目内可复现转换。
