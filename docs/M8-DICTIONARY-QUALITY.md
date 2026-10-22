# Glint M8 Dictionary Quality Baseline

- 日期：2026-10-22
- 样本：128 个，分为普通词、歧义词、技术词、短语和 blocklist
- 词典：CC-CEDICT、ECDICT、Wiktionary Chinese-English

## 当前结果

```text
total=128
top1=95 (74.2%)
top3=114 (89.1%)
missing=1
p95<2ms
```

`missing=1` 是预期被精确无效片段策略拦截的“你号”。`打`、`尼` 已恢复
正常查询。

报告中会逐条记录首选结果、前三个结果、延迟和是否命中预期：

```text
build/dictionary-benchmark.json
```

## 当前结论

取消 Override 强制首位并使用 schema-v2 后，旧的 130/130 结果不再成立。
旧样本中有 105 条与运行时 Override 重合，100% 主要证明 Override 表被加载，不能证明
开放词典的排序质量。

现在的 74.2% top-1 和 89.1% top-3 是没有静态答案强制覆盖时的真实回归
基线。schema-v2 把 top-1 从 64.8% 提升到 68.8%，候选净化进一步把它提升到
74.2%；top-3 从 79.7% 经 85.2% 提升到 89.1%。

## 既有能力

- 将 blocklist 放到 `DictionaryRouter` 全局生效，防止 Wiktionary 绕过
  CC-CEDICT/ECDICT 的过滤；当前默认策略只保留 `你号`；
- `model-first` 保持模型结果第一，并把词典和低优先级 Override 作为备选；
- 44 条上下文敏感 Override 只进入 `retiredOverrides` 候选池，61 条稳定项
  只作为有界排序提示和低优先级 fallback；
- CC-CEDICT 使用 schema-v2，保留 199,687 个义项和 125,109 个原始词条；
- 为“谢谢、英语、帮助”增加高置信度排序修正；
- 多词典结果合并，而不是第一本命中即返回；
- 加入 Wiktionary 简繁查询折叠，支持简体输入命中繁体词条。

## 重要说明

这个基准仍是小规模回归测试，不是绝对语言质量评测。它现在可用于观察
schema-v2 和排序改动的真实收益；M18/M20 的独立歧义样本用于上下文与
Override 决策。

## 句子路由

智能模式现在先查词典；词典未命中时，短语和句子会回退到本地模型。6 个汉字
左右、没有标点的文本也会被识别为句子，而不是误判为短语。

自检：

```text
smart sentence 今天天气不错 -> It's a nice day.
```
