# Glint Dictionary Sources

- 最近核对：2026-10-28
- 目标：筛选可用于离线安装的词典来源
- 判断标准：中文-英文覆盖、许可证、数据格式、质量、可再分发性

## 已接入

### CC-CEDICT

- 来源：[CC-CEDICT](https://cc-cedict.org/)
- 许可证：CC BY-SA
- 角色：中文词和短语的基础开放词典
- 状态：已内置；生产 schema-v2 保留 125,331 个原始词条和 199,703 个
  读音/义项
- 更新：用户可在“插件与模型”中手动检查；App 从 MDBG 官方地址下载，在本地构建
  SQLite 并校验后原子安装，失败时继续使用内置版本

```bash
python3 Tools/DictionaryBuilder/build_sqlite.py \
  --cedict-gz /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  --output Resources/Plugins/dict-cedict/cedict.sqlite3
```

该兼容脚本会调用 `glint-dictionary-builder`；解析和数据库生成只有 Swift 一份实现。

### ECDICT

- 来源：[ECDICT](https://github.com/skywind3000/ECDICT)
- 许可证：MIT
- 角色：英语词频和义项排序补充
- 状态：已内置；仅作为词频、Collins 和 Oxford 排序层，不作为完整中文义项库
- 数据：提交 `9c46923fb81a2eb6c264a3a1689562ea7bc56b6a`，CSV SHA256
  `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc`；
  生成 101,755 个中文词项和 152,449 条排序记录
- 更新：用户可在“插件与模型”中手动检查；App 通过提交 Atom 源检测 revision，
  下载固定 revision 的官方归档，校验 CSV 后流式重建 SQLite，失败时继续使用当前
  版本

```bash
python3 Tools/DictionaryBuilder/build_ecdict_ranker.py \
  --csv /tmp/ecdict.csv \
  --output /tmp/ecdict_rank.sqlite3 \
  --source-checksum d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc \
  --source-date 2026-10-20T02:25:07Z \
  --source-revision 9c46923fb81a2eb6c264a3a1689562ea7bc56b6a
```

该兼容脚本同样调用 `glint-dictionary-builder`，不会另行实现排序规则。

### Wiktionary / Kaikki

- 来源：[Kaikki Chinese](https://kaikki.org/dictionary/Chinese/)
- 许可证：CC BY-SA 4.0 + GFDL
- 角色：覆盖量大的开放中文词条，补充 CC-CEDICT/ECDICT
- 状态：已构建并随 App 提供 `dict-wiktionary-zh-en`，支持简繁查询；评估显示它能
  显著提高义项覆盖率，首项排序由 ECDICT 信号和模型兜底负责，不加载人工词表
- 注意：插件目录中的 `NOTICE.txt` 必须保留 Wiktionary 署名与许可证链接

## 评估后暂不接入

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

## 构建 Wiktionary

```bash
./scripts/build_wiktionary_dictionary.py \
  --output Resources/Plugins/dict-wiktionary-zh-en
```

该脚本流式处理 Kaikki JSONL，不保存原始 1.1GB 文件。
