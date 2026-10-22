# Glint Dictionary Source Research

- 调研日期：2026-10-20
- 目标：筛选可用于离线安装的词典来源
- 判断标准：中文-英文覆盖、许可证、数据格式、质量、可再分发性

## 已接入

### CC-CEDICT

- 来源：https://cc-cedict.org/
- 许可证：CC BY-SA
- 角色：中文词和短语的基础开放词典
- 状态：已内置；生产 schema-v2 保留 125,109 个原始词条和 199,687 个
  读音/义项

```bash
python3 Tools/DictionaryBuilder/build_sqlite.py \
  --cedict-gz /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  --output Resources/Dictionary/cedict.sqlite3
```

### ECDICT

- 来源：https://github.com/skywind3000/ECDICT
- 许可证：MIT
- 角色：英语词频和义项排序补充
- 状态：已内置；仅作为词频、Collins 和 Oxford 排序层，不作为完整中文义项库

### Wiktionary / Kaikki

- 来源：https://kaikki.org/dictionary/Chinese/
- 许可证：CC BY-SA 4.0 + GFDL
- 角色：覆盖量大的开放中文词条，补充 CC-CEDICT/ECDICT
- 状态：已构建 `dict-wiktionary-zh-en`，支持简繁查询；M19 规范化联合库
  证明其能显著提高义项覆盖率，但原始首项排序仍需 ECDICT 和人工 override
- 注意：目录和安装页必须保留 Wiktionary 署名与相同方式共享许可

## 评估后暂不接入

### IATE

- 来源：https://iate.europa.eu/download-iate
- 许可证：下载文件允许个人及商业再利用，但主要覆盖欧盟语言
- 结论：不作为中文-英文默认源；可作为未来欧盟术语包

### PanLex

- 来源：https://panlex.org/license/
- 许可证：CC BY-NC-SA 4.0
- 结论：默认商业版本不能直接分发；需要单独获得 PanLex 书面许可

### Microsoft Terminology

- 来源：https://learn.microsoft.com/en-us/globalization/reference/microsoft-terminology
- 格式：TBX
- 结论：技术术语质量高，但再分发条款需单独确认，暂不打包

### 商业词典

Oxford、Cambridge、Collins、Longman、现代汉语词典等需要正式授权或 API 合作，不能直接抓取和打包。

## 构建 Wiktionary

```bash
./scripts/build_wiktionary_dictionary.py \
  --output Resources/Plugins/dict-wiktionary-zh-en
```

该脚本流式处理 Kaikki JSONL，不保存原始 1.1GB 文件。
