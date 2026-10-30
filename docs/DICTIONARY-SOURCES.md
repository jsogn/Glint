# Glint Dictionary Sources

- 最近核对：2026-10-31
- 目标：筛选可用于离线安装的词典来源
- 判断标准：中文-英文覆盖、许可证、数据格式、质量、可再分发性

## 已接入

### CC-CEDICT

- 来源：[CC-CEDICT](https://cc-cedict.org/)
- 许可证：CC BY-SA
- 角色：中文词和短语的基础开放词典
- 状态：已内置；生产 schema-v3 使用 `terms` 与 `senses` 两张
  `WITHOUT ROWID` 表保留 125,331 个原始词条、203,301 条简繁查询映射和
  199,703 个义项。拼音不参与 Glint 展示或查询，因此不进入生产数据库
- 候选清洗：以引号开头的词条只提取引号内的头词，并丢弃逗号后的解释性
  定义；引号内的逗号保持不变
- 展示门控：超过 48 字符或 8 个英文词、或包含明确解释句式的候选不进入 HUD。
  CC-CEDICT 只有解释性 gloss 时视为未命中，继续按 ECDICT 和
  本地模型回退；不按普通逗号拆分专名或并列短语
- 更新：用户可在“插件与模型”中手动检查；App 从 MDBG 官方地址下载，在本地构建
  SQLite 并校验后原子安装，失败时继续使用内置版本

```bash
swift run --package-path Packages/GlintDictionary glint-dictionary-builder cedict \
  --input /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  --output Resources/Plugins/dict-cedict/cedict.sqlite3
```

解析和数据库生成只有 Swift 一份实现。

### ECDICT

- 来源：[ECDICT](https://github.com/skywind3000/ECDICT)
- 许可证：MIT
- 角色：英语词频和义项排序补充
- 状态：已内置；作为词频、Collins、Oxford 和考试标签排序层，同时可把
  CC-CEDICT 的多词释义拆成更高频的英文头词候选。权威结果少于三项时，允许带
  考试标签的 ECDICT 词作为低优先级补充；无标签词和独立回退结果不会覆盖权威项
- 数据：提交 `9c46923fb81a2eb6c264a3a1689562ea7bc56b6a`，CSV SHA256
  `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc`；
  生成 96,558 个中文词项和 144,791 条排序记录。schema-v3 使用
  `(term, english)` 主键的 `WITHOUT ROWID` 表，不再维护重复的次级词项索引。
  索引会忽略括号中的语境、人名/地名/影视元数据和标题式片段，避免把说明文字
  误当翻译
- 更新：用户可在“插件与模型”中手动检查；App 通过提交 Atom 源检测 revision，
  下载固定 revision 的官方归档，校验 CSV 后流式重建 SQLite，失败时继续使用当前
  版本

```bash
swift run --package-path Packages/GlintDictionary glint-dictionary-builder ecdict \
  --input /tmp/ecdict.csv \
  --output /tmp/ecdict_rank.sqlite3 \
  --source-checksum d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc \
  --source-date 2026-10-20T02:25:07Z \
  --source-revision 9c46923fb81a2eb6c264a3a1689562ea7bc56b6a
```

排序规则不会在 Python 中另行实现。

## 排序质量门禁

```bash
./scripts/benchmark_dictionary.sh
```

基准覆盖日常、通用、技术、歧义、短语和无效片段。短语以及词典源没有覆盖的
现代义项属于本地模型路径，单独报告；词典类别必须同时满足 `Top-1 >= 98%`、
`Top-3 >= 98%`，且明确列出的错误候选不得出现。回退链只采用第一个有结果的来源，
避免不同低质量来源相互污染。同一门槛在 CI 与 Release workflow 中执行。

## 评估后暂不接入

### Wiktionary / Kaikki

- 来源：[Kaikki Chinese](https://kaikki.org/dictionary/Chinese/)
- 许可证：CC BY-SA 4.0 + GFDL
- 状态：2026-10-31 从内置资源移除，不再随 App 分发或加载
- 数据：36 MB、227,203 条义项记录；其中约 88,000 个词条不在
  CC-CEDICT 和 ECDICT 中，但主要是繁体、方言、地名、人名和生僻表达
- 评估：150 条产品评测仅新增一个正确结果；50 条模型用词没有独立贡献；
  条目缺少频率信号，部分首项排序不可靠
- 结论：当前不进入默认词典链路；如未来出现明确的方言、繁体或生僻词需求，
  再作为独立可下载 SQLite 词典插件重新评估

### IATE

- 来源：[IATE](https://iate.europa.eu/download-iate)
- 许可证：下载文件允许个人及商业再利用，但主要覆盖欧盟语言
- 结论：不作为中文-英文默认源；可作为未来欧盟术语包

### PanLex

- 来源：[PanLex](https://panlex.org/license/)
- 许可证：CC BY-NC-SA 4.0
- 结论：默认商业版本不能直接分发；需要单独获得 PanLex 书面许可

### Microsoft Terminology

- 来源：[Microsoft Terminology](https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology)
- 格式：TBX
- 结论：技术术语质量高，但再分发条款需单独确认，暂不打包

### 商业词典

Oxford、Cambridge、Collins、Longman、现代汉语词典等需要正式授权或 API 合作，不能直接抓取和打包。
