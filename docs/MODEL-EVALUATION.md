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

- 完整句子优先使用模型，模型失败后回退词典；“词典优先”不会让普通词典释义
  覆盖完整的自然语言翻译。
- 单词和短中文术语仍优先使用毫秒级词典。
- 2–4 字短语在词典优先级高时保留词典结果；需要更高质量时由用户选择“模型优先”。
- 模型只在候选停留后执行，快速连续输入不会启动模型。
