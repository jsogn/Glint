# Glint M6 Multi-sense Dictionary

- 日期：2026-10-20
- 目标：单词和短语返回多个英文候选，按稳定规则排序，并保持 HUD 单行显示

## 数据模型

`TranslationResult` 现在包含：

- `options`: 多个 `TranslationOption`；
- 每个选项包含 `text` 和 `score`；
- `text` 返回排序第一项；
- `displayText` 返回适合 HUD 的前 2–3 项，并限制单行长度。

选项按分数降序排序，并进行大小写和标点无关的去重。

## 词典行为

### CC-CEDICT

- 解析全部英文义项，不再只取第一条；
- 清理 `to/the/a/an/be/of` 前缀和首尾标点；
- 合并多词义项；
- 使用 ECDICT 词频、Collins 和 Oxford 标记辅助排序；
- 人工 override 支持有序候选数组，并拥有最高优先级。

### ECDICT

- CEDICT 无结果时返回最多 3 个英文候选；
- 继续使用词频排序并过滤过短噪声词条。

## HUD

- HUD 显示排序后的多个结果，例如：
  - `design · plan`
  - `program · procedure · process`
  - `complex · complicated`
- 第一项是当前最高排序结果；
- 超过一行容量时自动减少候选数量。

## 当前限制

没有上下文时，排序只能提供合理默认顺序，不能保证正确语义。
真正的上下文消歧需要读取光标附近文本，属于后续可选功能。
