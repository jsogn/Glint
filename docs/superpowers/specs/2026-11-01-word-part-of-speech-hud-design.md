# 单词译项词性提示设计

- 状态：已确认（最终英文词性索引）
- 日期：2026-11-01
- 范围：Glint 0.7.x 之后的单词级词性提示

## 1. 结论

Glint 在“选中”模式中，为最终英文译项增加紧凑的英文词性缩写。
视觉顺序固定为“英文词在前、词性在后”，例如：

```text
design n./v.    devise v.    about adv./prep.
```

词性属于具体英文译项，不属于中文候选。没有可靠词性数据时不猜测、不显示占位符，
短语和完整句子不显示词性。

固定 ECDICT revision 的 `pos` 比例列为空，第一版解析 `translation` 字段中每条释义
行开头的标签，并按英文词自身建立词性索引。中文到英文的翻译完成后，最终英文单词
统一查询该索引并获得词性；词性不依赖中文词项或翻译来源。

该功能只增加单词级词性元数据，不引入中文词性标签、解释、例句、音标、发音信息或
百分比。插入和朗读仍只消费英文译文正文。

## 2. 目标

1. 帮助用户区分同一中文词对应的不同英文词及其常见用法。
2. 保持 HUD 单行、轻量，不把 Glint 变成完整词典页。
3. 只展示英文词性索引明确提供的数据，不为模型结果凭空生成词性。
4. 保持现有候选读取、翻译路由、隐私边界和快捷操作不变。
5. 空间不足时优先保留译文，词性是可降级信息。

## 3. 非目标

- 不显示“名词、动词”等中文词性标签。
- 最多显示两个词性，也不显示词性占比。
- 不显示释义、音标、例句、搭配、时态变化或助记信息。
- 不为短语、完整句子或多词译项生成词性。
- 不根据单词后缀、上下文或模型回答推测词性。
- 不在“一栏”模式显示词性。
- 词性默认显示，但用户可以关闭；偏好持久化到显示设置。
- 不区分 `vt.`、`vi.` 等及物性，除非未来出现可验证的数据源。
- 不改变词条翻译、插入、朗读、缓存、权限或候选读取的现有隐私边界。

## 4. 用户可见行为

### 4.1 适用范围

只有同时满足以下条件的译项显示词性：

1. 当前显示设置为“选中”模式。
2. 用户未关闭“显示词性”设置。
3. 当前 HUD 宽度允许显示词性。
4. 译项文本是非空英文单词，不含空白，至少包含一个拉丁字母。
5. 该英文表面词能通过精确、规范化的键匹配到英文词性数据。
6. 至少有一个可识别的受支持词性。

连字符或撇号单词可以显示词性，例如 `well-known adj.`。多词译项如
`look up`、`bullet screen` 不显示。汉字、数字或标点本身不算英文单词。

### 4.2 词性缩写与顺序

第一版支持以下可视缩写：

| 规范化词性 | 可视缩写 | VoiceOver 全称 |
| --- | --- | --- |
| noun | `n.` | noun |
| verb | `v.` | verb |
| adjective | `adj.` | adjective |
| adverb | `adv.` | adverb |
| preposition | `prep.` | preposition |
| pronoun | `pron.` | pronoun |
| conjunction | `conj.` | conjunction |
| determiner | `det.` | determiner |
| numeral | `num.` | numeral |
| interjection | `interj.` | interjection |

多词性按上表顺序显示，不按 ECDICT 原始顺序。视觉使用英文缩写；VoiceOver
展开为英文全称，不朗读字母或中文名称。

### 4.3 选择规则

1. 对最终得到的英文译项进行判断；只有单个英文单词进入词性查询。
2. 将 ECDICT `translation` 中的字面量 `\n` 解释为释义行分隔符。
3. 解析每个英文词所有释义行开头的词性标签，例如 `n.`、`v.`、`vt.`、`vi.`、
   `a.`、`adj.`、`adv.`、`prep.`、`pron.`、`conj.`、`num.`、`int.`、`interj.`。
4. 词性存储键为规范化后的英文单词，不包含中文词项。
5. 同一英文词在同一词性标签下重复出现时只保留一次。
6. 按释义行首次出现顺序保留最多两个不同词性，再按第 4.2 节固定顺序显示。
7. 无标签、未知标签、`abbr`、`pref`、`suf`、`phr` 等不在第一版目标内的标签
   不产生词性，但不影响英文词进入排名索引。
8. 全部解析失败时返回空数组，不影响译文显示。

示例：

| 原始数据 | 显示 |
| --- | --- |
| 模型或词典得到 `design`，ECDICT 有 `n.`/`v.` | `n./v.` |
| 模型或词典得到 `convenient`，ECDICT 有 `a.` | `adj.` |
| 模型或词典得到 `user`，ECDICT 有 `n.` | `n.` |
| 多词短语或 ECDICT 无该英文词 | 不显示 |

### 4.4 视觉规范

- 视觉形式固定为 `design n./v.`。
- 英文词保持现有主文字字号、字重和颜色。
- 词性字号约为正文的 75%，最低 9pt；默认 14pt 下约为 10.5pt。
- 词性使用当前 HUD 外观解析出的次要文字颜色。
- 词性不加括号、圆点、分隔符、背景胶囊、上标或阴影。
- 英文词与词性之间使用一个普通空格。
- HUD 高度、圆角、材质、动画和候选间距均不改变。
- 新结果替换文字时沿用现有内容过渡；Reduce Motion 规则不变。

### 4.5 宽度与降级

- 面板自然宽度测量必须包含词性。
- 如果带词性的完整布局超过当前可用宽度，同一次展示中去掉全部词性，只显示纯译文。
- 不得为了保留词性而截断英文词、缩小字号、改变显示数量、增加第二行或改变 HUD
  高度。
- 去掉词性后仍超出宽度时，沿用现有 HUD 定位和宽度策略。

### 4.6 用户开关

“显示与触发”页提供“显示词性”开关，默认开启。关闭后：

- 选中模式只显示英文译文，不创建词性展示选项。
- 一栏模式行为不变。
- 插入、朗读和快捷键不受影响。
- 偏好键为 `display.showsPartsOfSpeech`，已有用户升级后默认开启。

## 5. 数据与领域模型

### 5.1 GlintCore

新增 `PartOfSpeech: String, CaseIterable, Sendable, Equatable, Hashable`，包含第
4.2 节的十个规范化值。领域层提供固定排序、可视缩写和 VoiceOver 全称，不引用
AppKit 或 SwiftUI。

`TranslationOption` 增加：

```swift
public let partsOfSpeech: [PartOfSpeech]
```

初始化参数默认空数组，保持现有调用兼容。`TranslationResult` 按现有英文表面去重时，
若多个重复项携带不同词性，合并其词性并按固定顺序去重。`primaryOnly` 保留首选
译项的完整元数据。

词性不是 `TranslationOption.text` 的一部分。任何日志、状态文本、插入或朗读都不得
拼接词性。

### 5.2 ECDICT 词性索引

ECDICT builder schema 从 `ecdict-rank-v3` 升级为 `ecdict-rank-v4`，新增独立表：

```sql
CREATE TABLE english_parts_of_speech (
    english_key TEXT NOT NULL,
    parts_of_speech TEXT NOT NULL,
    PRIMARY KEY (english_key)
) WITHOUT ROWID;
```

- `english_key` 使用 Unicode 规范化、去首尾空白和小写后的精确英文表面键。
- 该表只保存英文词性元数据，不改变 `ranks` 表或现有排序。
- `parts_of_speech` 以 `/` 分隔规范化词性 raw value，例如 `noun/verb`。
- 只收录不含空白的英文单词；短语不进入词性表。
- builder 先把 `translation` 的 `\n` 解码为行，再逐行识别行首标签。
- `n.` 映射名词；`v.`、`vt.`、`vi.`、`aux.` 映射动词；`a.`、`adj.` 映射
  形容词；`adv.`、`ad.` 映射副词；`prep.`、`pron.`、`conj.`、`num.`、
  `det.`、`int.`、`interj.` 分别映射对应词性。
- `abbr.`、`pref.`、`suf.`、`phr.`、`un.`、`na.`、`pl.`、`vbl.` 等其他标签
  不进入第一版词性结果。
- 同一个英文词从多个释义行得到词性时，按行首次出现顺序去重，最多保留两个，再按
  固定顺序序列化。
- `ECDICTRanker` 实现 `PartOfSpeechProviding`，按单个英文词查询词性。
- 表缺失、内容损坏或包含未知 raw value 时返回空数组，不能使词典命中整体失败。

`SmartRouter` 在词典优先、模型优先、智能融合和失败回退得到最终结果后，统一对
单词译项执行英文词性补全。词典、Apple Translation、MLX 和融合结果使用同一查询。
- 英文词性提取与排名资格完全独立；词频高于排名阈值、没有词频或只存在于词性数据
  中的英文词仍可进入 `english_parts_of_speech`。

### 5.3 通用 SQLite 词典

`GenericSQLiteDictionary` 读取可选的 `part_of_speech` 列。该字段描述 `target`
英文词的词性，可包含用 `/`、逗号或分号分隔的受支持标准缩写或规范化英文全称；
匹配大小写不敏感。缺少该列时保持现有行为，不要求旧插件升级。

## 6. 展示数据流

```text
ECDICT translation 释义行标签
  → ECDICT builder 按英文词聚合
  → english_parts_of_speech
  → ECDICTRanker
  → PartOfSpeechProviding
  → SmartRouter 对最终英文选项补全
  → TranslationOption.partsOfSpeech
  → CandidateTranslationPresentation
  → HUDItem.partsOfSpeech
  → HUD 分段渲染
```

### 6.1 翻译展示模型

新增只用于展示的结构：

```swift
struct CandidateTranslationOptionPresentation: Sendable, Equatable {
    let text: String
    let partsOfSpeech: [PartOfSpeech]
}
```

`CandidateTranslationPresentation` 增加显示选项数组，同时保留纯字符串
`insertionOptions` 作为插入、朗读和快捷键动作的唯一输入。选中模式下显示选项
携带词性；一栏模式下显示选项数组必须为空，HUD 继续使用现有纯译文路径。

`HUDItem` 增加默认空数组的 `partsOfSpeech`。`HUDEventCoordinator` 只在选中模式把
元数据传入 HUD，一栏模式继续走现有纯译文路径。

### 6.2 合并与缓存

- `SmartRouter` 在模型优先和智能融合中按现有英文表面键合并选项时，合并词性而
  不是丢弃后加入的元数据。
- `DictionaryRouter` 在词典表面清洗后保留词性；一个源选项被拆成多个英文表面时
  丢弃该元数据，避免把单一词性错误复制到不同语义。
- `TranslationMemo` 缓存完整 `TranslationResult`，包括词性。
- 配置 token 已包含词典插件版本和哈希；ECDICT schema/资源升级时 bump 插件版本，
  防止复用旧内存结果。
- 词性元数据只存在内存缓存和只读 SQLite 中，不新增候选或译文持久化。

## 7. HUD 渲染细节

`HUDItem` 的视觉文本由两段组成：

1. `text`：英文译项正文，使用现有主文字样式。
2. `partsOfSpeech`：规范缩写串，使用按比例缩放后的次要样式。

两段共享单行基线，不能被拆分到不同 `HStack` 项之间。编号与词性无关，仍显示在
整个译项前。词性存在时，`HUDLayoutPlan` 的宽度估算使用正文和词性合并后的宽度；
不包括词性的估算不得用于最终面板尺寸。

宽度降级由展示层决定，不修改领域结果。HUD 更新时不得因词性出现或消失创建新的
SwiftUI 内容根视图，也不得增加 `NSPanel`。

## 8. 错误与兼容

- ECDICT 释义行无标签、标签未知或英文词不在索引中：省略词性。
- `english_parts_of_speech` 表缺失、内容损坏或含未知 raw value：正常显示译文，静默省略
  词性。
- 自定义词典 `part_of_speech` 格式不支持：忽略无法识别的部分。
- 旧词典 schema 不兼容：使用现有核心词典原子修复和 bundled 回退机制。
- 模型返回多词短语或句子：不尝试拆分后添加词性。
- 词性元数据不得影响翻译排序、快捷编号、插入内容或朗读内容。
- 任何错误不得弹窗或 Toast；继续遵循静默降级原则。

## 9. 测试

### 9.1 GlintCore

- `TranslationOption` 默认词性为空，现有初始化行为不变。
- 固定词性顺序、缩写和 VoiceOver 全称正确。
- 重复英文表面合并词性并去重。
- `primaryOnly`、排序和现有去重行为不回归。
- `TranslationMemo` 命中时保留词性。

### 9.2 GlintDictionary

- 英文 `design` 的 `n.` 与 `v.` 释义行生成 `design n./v.`。
- 英文 `convenient` 的 `a.` 释义行生成 `convenient adj.`。
- `a.`、`adj.`、`vt.`、`vi.`、`adv.`、`prep.` 等标签映射正确。
- 未知标签不产生词性，但英文词仍进入排名索引。
- 同一英文词最多保留两个不重复词性，并按固定顺序序列化。
- 模型优先模式中的单词模型结果也获得同一词性。
- ECDICT schema-v4 构建、兼容检查、bundled 数据库校验和旧 schema 拒绝路径。
- 通用 SQLite 有/无 `part_of_speech` 列均可正常工作。
- 词性查询失败不影响词典结果。

### 9.3 GlintMac

- 选中模式把词性传递到展示模型。
- 一栏模式不暴露词性。
- 插入选项、朗读选项和快捷键只包含英文正文。
- 模型与词典结果合并后保留词典词性。
- 候选 revision 变化和取消任务时词性随着旧展示一起失效。

### 9.4 GlintUI

- HUD 在 12pt、14pt、18pt 字号下保持单行。
- 浅色、深色、玻璃和纯色背景下次要颜色可读。
- 宽度包含词性；窄空间先去掉词性。
- 无词性和一栏模式布局与当前版本一致。
- VoiceOver 朗读英文全称，视觉仍显示缩写。

### 9.5 集成与真实 App

- 使用能够产生单词译项的输入完成真实候选验证。
- 验证多词性、单词性、无词性和多词译项四种情况。
- 验证插入不包含 `n./v.`，朗读不读词性。
- 验证 1–9 个译项及窄屏降级。
- 替换已安装 ECDICT 数据并重新加载后，后续词性查询使用新数据。
- 修改跨模块后执行完整 `./scripts/test.sh`。
- 执行至少一次增量 Debug 构建；涉及 UI 样式时使用真实 App 检查浅色、深色和
  窗口缩放。

## 10. 性能与资源

- 词性保存在独立词性表中，排名查询只增加一次本地 SQLite 元数据读取。
- 不新增模型调用、网络请求、轮询或后台常驻任务。
- 词性只随规范化后的 `english_key` 存储，不保存释义原文。
- 现有内存 LRU 容量和候选延迟目标不变。
- 数据库新增资源大小和构建耗时需在实现阶段记录；不把实测数据写入用户文案。

## 11. 文档同步

实现时必须同步：

- `AGENTS.md`：允许单词级标准词性缩写，继续禁止解释、例句、音标和中文词性标签。
- `docs/ARCHITECTURE.md`：增加 `PartOfSpeech`、选中模式渲染和降级规则。
- `docs/DICTIONARY-SOURCES.md`：记录 ECDICT 释义行标签、英文词关联和 schema-v4。
- 对应 Release Notes：使用用户可理解的语言描述，不写内部算法或本机速度。

## 12. 发布与迁移

- 重新生成 bundled `ecdict_rank.sqlite3`。
- 更新 ECDICT manifest 的 schema/runtime 兼容版本、版本号和 SHA256。
- 验证 App 启动时可原子修复旧 schema，不会被旧安装覆盖。
- 仅新增 `display.showsPartsOfSpeech`，默认开启；不需要迁移旧数据。
- ad-hoc 测试包和正式分发继续遵循现有 Release 门禁。

## 13. 成功标准

1. 选中模式中，符合条件且数据可靠的单词译项显示最多两个标准词性缩写。
2. 所有无可靠数据的场景只显示译文，没有词性猜测或残留占位。
3. 词性从不进入插入、朗读、翻译文本、日志或持久化候选数据。
4. HUD 高度、单行规则、定位和无障碍行为不回归。
5. 词典构建、旧 schema 修复、模块测试和完整回归全部通过。
