# Glint M8 Dictionary Quality Baseline

- 日期：2026-10-20
- 样本：130 个，分为普通词、歧义词、技术词、短语和 blocklist
- 词典：CC-CEDICT、ECDICT、Wiktionary Chinese-English

## 当前结果

```text
total=130
top1=130 (100.0%)
top3=130 (100.0%)
missing=3
p95=0.50ms
```

`missing=3` 是预期被 blocklist 拦截的“打 / 尼 / 你号”，不是查词失败。

报告中会逐条记录首选结果、前三个结果、延迟和是否命中预期：

```text
build/dictionary-benchmark.json
```

## 本次修复

- 将 blocklist 放到 `DictionaryRouter` 全局生效，防止 Wiktionary 绕过
  CC-CEDICT/ECDICT 的过滤；
- 为“谢谢、英语、帮助”增加高置信度排序修正；
- 多词典结果合并，而不是第一本命中即返回；
- 加入 Wiktionary 简繁查询折叠，支持简体输入命中繁体词条。

## 重要说明

这个基准是回归测试，不是绝对语言质量评测。部分技术词预期来自 Glint
override，因此结果会偏向 100%；它主要用于防止新词典接入、排序改动或
blocklist 修改造成回归。后续需要加入独立人工标注样本，并逐步引入上下文
评测。

## 句子路由

智能模式现在先查词典；词典未命中时，短语和句子会回退到本地模型。6 个汉字
左右、没有标点的文本也会被识别为句子，而不是误判为短语。

自检：

```text
smart sentence 今天天气不错 -> It's a nice day.
```
