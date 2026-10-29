# Glint Model Evaluation

- 最近核对：2026-10-29
- 用例：`Resources/Evaluation/dictionary-benchmark.json` 中 `phrase` 与 `model`
  类别，共 13 条
- 工具：`Tools/GlintEval` 的 `TranslationCompare`

## 本次结果

测试使用内置 OPUS-MT int8 和本机已安装的 Hy-MT2 1.8B 4-bit。质量字段来自工具
对单个参考译文的精确率和 token F1；同义表达不会被完整计入，因此只能用于横向
比较，不等同于产品准确率。

| 模型 | Exact | Token F1 | p95 |
| --- | ---: | ---: | ---: |
| OPUS-MT int8 | 53.8% | 69.1% | 35.6 ms |
| Hy-MT2 1.8B 4-bit | 76.9% | 86.2% | 113.9 ms |

两条模型路径都能正确处理大多数问候语和完整短句。Hy-MT2 对“复盘”输出
`Review`；OPUS-MT 输出 `Duplicate`，仍是模型路径的已知语义缺口。

## 路由结论

- “智能融合”并行使用模型与词典结果，以精确候选共识提高排序质量；用户仍可
  明确选择“词典优先”或“模型优先”覆盖融合结果。
- 完整句子优先使用模型，模型失败后回退词典；“词典优先”不会让普通词典释义
  覆盖完整的自然语言翻译。
- 单词和短中文术语仍优先使用毫秒级词典。
- Hy-MT2 和 Index-Translate 使用各自官方翻译模板，不附加通用风格指令；
  Qwen3 使用 system/user 分离的非 thinking 模式；未知模型默认只发送原文。
- Hy-MT2 使用官方采样参数，Index-Translate 使用贪心解码；通用模型不能共用
  一套解码参数。
- 短输入的模型结果如果与翻译指令高度重合，按无效结果丢弃并回退词典。
- 未知市场或本地模型的安装验证会依次尝试直接原文、翻译指令和 system 指令，
  只有通过固定短词探测的协议才会被保存并用于后续请求。
- 2–4 字短语在词典优先级高时保留词典结果；需要更高质量时由用户选择“模型优先”。
- 模型只在候选停留后执行，快速连续输入不会启动模型。

## 模式对照

- 用例：模式专项用例与词典回归用例合并去重后共 150 条
- 模型：OPUS-MT int8、Hy-MT2 1.8B 4-bit

```bash
swift build \
  --package-path Tools/GlintEval \
  --product TranslationModeCompare

Tools/GlintEval/.build/debug/TranslationModeCompare \
  --output build/translation-mode-benchmark.json
```

| 模型 | 模式 | Top-1 | Top-3 | p95 |
| --- | --- | ---: | ---: | ---: |
| OPUS-MT | 智能融合 | 143/150 | 144/150 | 31.7 ms |
| OPUS-MT | 词典优先 | 144/150 | 144/150 | 31.4 ms |
| OPUS-MT | 模型优先 | 100/150 | 144/150 | 33.1 ms |
| Hy-MT2 | 智能融合 | 149/150 | 150/150 | 132.8 ms |
| Hy-MT2 | 词典优先 | 149/150 | 149/150 | 133.0 ms |
| Hy-MT2 | 模型优先 | 138/150 | 150/150 | 132.5 ms |

智能融合保留严格模式的语义，同时避免无词典支持的模型词语无条件压过多个词典
候选。切换模型仍会改变融合结果，例如“关于”在 OPUS-MT 下为 `about`，在
Hy-MT2 下为 `concerning`；“设置”分别为 `set` 和 `set up`。

由于词典优先在 Top-1 上仍略优且不需要为普通短词等待模型，默认模式保持
“词典优先”。智能融合作为需要模型参与排序时的可选模式；模型优先和词典优先
继续提供严格的显式覆盖语义。
