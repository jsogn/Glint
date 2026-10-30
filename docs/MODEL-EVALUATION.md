# Glint Model Evaluation

- 最近核对：2026-10-30
- 用例：`Resources/Evaluation/dictionary-benchmark.json` 中 `phrase` 与 `model`
  类别，共 13 条
- 工具：`Tools/GlintEval` 的 `TranslationCompare`

## 本次结果

测试使用同一 OPUS-MT int8 数据和本机已安装的 Hy-MT2 1.8B 4-bit。质量字段来自工具
对单个参考译文的精确率和 token F1；同义表达不会被完整计入，因此只能用于横向
比较，不等同于产品准确率。

| 模型 | Exact | Token F1 | p95 |
| --- | ---: | ---: | ---: |
| OPUS-MT int8 | 53.8% | 69.1% | 35.6 ms |
| Hy-MT2 1.8B 4-bit | 76.9% | 86.2% | 113.9 ms |

两条模型路径都能正确处理大多数问候语和完整短句。Hy-MT2 对“复盘”输出
`Review`；OPUS-MT 输出 `Duplicate`，仍是模型路径的已知语义缺口。

## Apple Translation 对照

苹果系统翻译通过公开 `Translation` 框架和 SwiftUI `translationTask`
调用。评测在同一进程、同一批 150 条用例上依次执行系统翻译与 OPUS-MT
OPUS-MT，先做一轮不计时的首次调用和全量预热，再执行 3 轮计时。主机为
macOS 26.6.2 arm64，系统语言包已完成安装。

质量使用现有规则：只比较首选译文，转成小写并移除标点和空白后，命中任一
可接受参考即记为 Top-1。该规则偏低，因为部分自然同义表达不计分。

| 引擎 | Top-1 | 缺失 | p50 | p95 | 首次调用 | 加载/准备 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple Translation | 121/150（80.7%） | 0 | 18.8 ms | 27.1 ms | 110.4 ms | 4.2 ms |
| OPUS-MT int8 | 100/150（66.7%） | 0 | 13.8 ms | 26.6 ms | 22.5 ms | 77.6 ms |

按 Glint 的候选分类：

| 候选类型 | Apple Translation | OPUS-MT |
| --- | ---: | ---: |
| phrase | 112/139 | 94/139 |
| sentence | 9/11 | 6/11 |
| 合计 | 121/150 | 100/150 |

苹果翻译的优势主要出现在自然短语和完整短句。例如：

- “弹幕”：`Bullet screen`，OPUS-MT 为 `The curtain.`
- “需要”：`Need`，OPUS-MT 为 `Yes.`
- “今天天气不错”：`The weather is nice today.`，OPUS-MT 为
  `It's a nice day.`
- “请打开文件”：`Please open the file.`，OPUS-MT 为
  `Open file, please.`

OPUS-MT 在部分技术词和常见词上更准确，例如“用户”输出 `User`，苹果输出
`Consumer`；“默认”输出 `Default`，苹果输出 `Tacitly approve`；“内存”
输出 `Memory`，苹果输出 `Internal storage`。因此系统翻译不能直接取代
词典，也不适合无条件取代所有模型输入。

首次运行语言包尚未安装时，系统状态为 `supported`，
`prepareTranslation()` 会进入可见下载流程；本次准备调用耗时约 26.9 秒，
实际总等待还取决于用户确认、网络和后台下载。语言包安装后再次启动的
准备耗时为 4.5 毫秒。稳定推理没有明显的速度优势，但 p95 与 OPUS-MT
基本持平。

结论：苹果系统翻译值得作为“已安装语言包时的短语/短句优先来源”，失败后
由现有路由回退词典，不自动切换到 OPUS-MT；普通词和技术术语继续词典优先。
苹果系统翻译现为默认翻译模型；OPUS-MT 作为可选在线模型保留，可随时卸载。

重新生成对照报告：

```bash
./scripts/run_apple_translation_compare.sh
```

报告写入 `build/apple-translation-benchmark.json`。首次运行需要在系统弹窗中
确认下载中文和英文语言包。

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

GLINT_CT2_LIBRARY="$PWD/Resources/CTranslate2Runtime/bin/libglintct2.dylib" \
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
