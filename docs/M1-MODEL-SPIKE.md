# Glint M1 Model Spike

- 日期：2026-10-19
- 机器：MacBook Pro，Apple M4 Pro，48GB，macOS 26.6.2
- Python：3.11.13（uv venv）
- 评测集：`Tools/ModelLab/eval/cases.json`
- 原始结果：`Tools/ModelLab/results/*.json`

> 2026-10-20 更新：产品决策已改为“词典优先；任何非空输入未命中词典都交给模型”。
> Qwen3 0.6B / 1.7B / 4B 已接入 MLX Swift，OPUS-MT 继续作为轻量默认路径。
> 新增 Hy-MT2 1.8B 与 Index-Translate 2B 专用翻译模型；同测试集下 Hy-MT2
> p50 49ms、Index p50 53ms，Qwen3 1.7B 为 141ms。Qwen 系列仍保留用于多语言扩展。
> 运行时和安装验证详见 `docs/M9-LOCAL-MODEL-RUNTIME.md`。

## 1. 结论

1. **单词/短语仍应词典优先。** 三个模型都会在无上下文时猜测义项；但按照当前产品决策，词典未命中后仍交给当前模型，而不是直接隐藏。
2. **OPUS-MT 是默认轻量翻译插件的胜出者。** CTranslate2 int8 版本只有 77MB，p50 18.7ms、p95 41.2ms、峰值约 256MB；短句质量对“轻量默认”够用。
3. **Qwen3-4B 是高质量插件。** p50 166.6ms、p95 218.9ms、峰值约 2.7GB；短句自然度明显最好，但需要 16GB 级内存更稳妥。
4. **M2M100 不建议保留为默认预设。** p50 255ms、p95 397ms，质量没有超过 OPUS/Qwen，反而更慢、更重。
5. **智能模式必须调整：**
   - 单词/短语：只查词典；未命中或歧义 → 不显示；
   - 短句：交给翻译插件；
   - 纯模型模式保留，但应标注为实验性，尤其是单词结果。

## 2. 评测集

50 条用例，其中 45 条参与翻译评测，5 条为歧义/跳过用例：

- 20 个单词；
- 15 个短语/业务表达；
- 10 个短句；
- 3 个歧义词 + 2 个数字/emoji 跳过项。

覆盖了 Glint 的核心场景：职场/技术词汇、固定短语、自然短句、歧义词和多义表达。

## 3. 运行指标

| 模型 | 模型 ID | 加载 | p50 | p95 | 峰值 RSS | 缓存体积 |
|---|---|---|---:|---:|---:|---:|
| OPUS-MT | `Helsinki-NLP/opus-mt-zh-en` | 5.24s（已缓存） | 41.5ms | 79.9ms | 682MB | 601MB |
| **OPUS-MT CT2 int8（生产路径）** | 本地转换 `opus-ct2-int8` | **0.15s** | **18.7ms** | **41.2ms** | **256MB** | **77MB** |
| Qwen3-0.6B | `mlx-community/Qwen3-0.6B-4bit` | 19.79s（首次） | 49.8ms | 66.0ms | 876MB | 351MB |
| **Qwen3-1.7B** | `mlx-community/Qwen3-1.7B-4bit` | 2.65s（已缓存） | **141.5ms** | **190.3ms** | **1.47GB** | **984MB** |
| M2M100 | `facebook/m2m100_418M` | 95.31s（首次含下载） | 255.2ms | 397.2ms | 2.7GB | 3.6GB |
| Qwen3-4B | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 19.33s（已缓存） | 166.6ms | 218.9ms | 2.7GB | 4.2GB |

说明：

- OPUS/M2M100 使用 PyTorch CPU；Qwen 使用 MLX 4-bit。
- OPUS CT2 int8 是正式版默认路径，已用 `ct2-transformers-converter` 转换并实测。
- 首次运行包含模型下载，加载时间不能直接横比；OPUS 首次约 99s，Qwen 首次约 132s。
- RSS 不能完整反映 MLX/GPU 的统一内存；Qwen 首次运行曾达到约 4.6GB。
- OPUS CT2 的 tokenizer 必须补 `</s>` 源端 EOS，否则会输出重复的乱码；本次已在 `run_eval_ct2.py` 修正。

## 4. 质量结果

严格归一化 exact match（小写、去标点、去冠词）：

| 模型 | 单词 20 | 短语 15 | 短句 10 |
|---|---:|---:|---:|
| OPUS-MT（PyTorch） | 4 | 2 | 2 |
| OPUS-MT CT2 int8 | 4 | 2 | 1 |
| M2M100 | 2 | 2 | 0 |
| Qwen3-4B | 11 | 5 | 4 |

exact match 对短句偏严格；人工快速复核的自然度大致是：

- Qwen3-4B：10/10 短句可用，接近自然表达；
- OPUS-MT：约 7/10 短句可用，个别用词生硬；
- M2M100：约 5/10 短句可用，常见直译和断句问题。

## 5. 代表性输出

| 输入 | OPUS-MT | M2M100 | Qwen3-4B |
|---|---|---|---|
| 算法 | Algorithms | The algorithm | **algorithm** |
| 复盘 | Duplicate | Repeated | **review and analyze**（仍不够“retrospective”） |
| 迭代 | It's an alternator. | The iteration | **iteration** |
| 兜底 | I'll take care of it. | The bottom. | **backstop** |
| 颗粒度 | particle size | Particularity | **grain size**（业务语境应为 granularity） |
| 拉齐认知 | Ratsy knows it. | Rashid is aware. | **Raise awareness**（语义不对） |
| 灰度发布 | Grayscale Release | Released as gray | **Grayscale release**（业务语境应为 canary release） |
| 向上管理 | Upward Management | Management upward. | **Upward management**（更自然是 managing up） |
| 你好吗 | How are you? | Hello well? | **How are you?** |
| 今天天气不错 | It's a nice day. | The weather is good today. | **The weather is nice today.** |
| 这个方案需要再讨论 | This program needs to be revisited. | This plan needs to be discussed again. | **This plan needs further discussion.** |
| 这个功能什么时候上线 | When does this function go online? | When this function is on line? | **When will this feature go live?** |

## 6. 关键发现

### 6.1 单词/短语是词典问题，不是模型问题

即使 Qwen3-4B，也会把“复盘”翻成 “review and analyze”、把“颗粒度”翻成 “grain size”、把“拉齐认知”翻成 “Raise awareness”。这些不是更好的模型能稳定解决的问题，而是需要：

- 业务/技术词表；
- 人工 override；
- 词频和语境排序；
- 必要时不显示。

因此智能模式不能把单词未命中的情况交给模型硬猜。

### 6.2 OPUS-MT 适合做默认轻量插件

- 延迟最低；
- 内存最小；
- CTranslate2 int8 只有 77MB，适合作为默认下载插件；
- 短句质量对“快速提示”够用；
- 单词/短语质量差，但这部分本来就应该由词典处理。

### 6.3 Qwen3 1.7B 是默认 MLX 均衡档，4B 是高质量档

- 短句最自然；
- 单词对应也明显优于两个专用翻译模型；
- 但仍是“最常用义项”而非语境消歧；
- Qwen3-1.7B 实测 p50 141.5ms、p95 190.3ms、约 1.47GB RSS，短句完整度明显优于 0.6B，作为 MLX 均衡档更合适。
- Qwen3-4B 的 p50 为 166.6ms，4GB 级模型缓存和 2.7–4.6GB 内存更适合 16GB 以上机器。
- Qwen3-0.6B 仅适合低内存快速档；复杂句会出现漏主语、截断或错误表达。

### 6.4 M2M100 可以直接淘汰

- 比 OPUS 慢约 6 倍；
- 比 OPUS 重约 4 倍；
- 质量没有明显优势；
- 不应出现在默认插件目录中。

## 7. 建议的产品/路由调整

建议把 PRD 更新到 v0.3：

```text
单词/短语：
  词典命中 → 显示英文对应词
  未命中/歧义 → 不显示

短句：
  OPUS-MT（默认轻量）或 Qwen3-4B（高质量插件）→ 自然翻译

纯模型模式：
  保留，但标注为实验性；单词结果不作为默认推荐
```

## 8. 下一步

### M2

1. 用 CC-CEDICT + 业务/技术词表实现词典；
2. 增加 100 条单词/短语金标，建立“最佳英文对应词”排序；
3. 将已转换的 OPUS CTranslate2 int8 接入 `GlintInference`；
4. 接入 Qwen3-4B MLX 作为可选高质量插件；
5. 更新 SmartRouter：单词/短语不再模型兜底；
6. 更新 PRD v0.3 和插件预设列表。

### 暂不做

- 不需要为了单词质量继续堆更大的通用 LLM；
- 不需要保留 M2M100；
- 不需要把 Qwen 作为默认模型。

## 9. 原始数据

- `Tools/ModelLab/results/opus.json`
- `Tools/ModelLab/results/opus-ct2.json`
- `Tools/ModelLab/results/m2m100.json`
- `Tools/ModelLab/results/qwen.json`
