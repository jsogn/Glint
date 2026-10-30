# Glint ModelLab

模型实验区。这里只做模型对比，不进入 App 安装包。

历史选型结果保留在 Git 历史中。

## 目标

对比：

- OPUS-MT zh-en CTranslate2 int8
- Hy-MT2 1.8B 4-bit
- Index-Translate 2B 4-bit
- Qwen3 0.6B / 1.7B / 4B 4-bit

## 测试集

`eval/cases.json` 是当前 50 条评测集，覆盖：

- 单词；
- 成语/固定短语；
- 短句；
- 歧义词；
- 不应显示的数字/emoji/专名。

## 指标

- 单词英文对应准确率；
- 短句自然度（1–5 分人工评分）；
- 首 token 延迟、完整输出延迟 p95；
- 峰值内存；
- 模型体积；
- 是否出现解释、中文、引号或长句。

## 产出

- `Tools/ModelLab/results/` 下的原始结果

## 约束

- Python 只用于实验和模型转换；
- 不把 Python 或模型文件放进 App；
- 模型下载和转换实验不进入 App 运行时。

## 上下文评估

语料和 runner：

```bash
python3 Tools/ModelLab/eval/run_context_eval.py --dry-run
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/ModelLab/eval/run_context_eval.py
```

词典候选与上下文重排：

```bash
swift run --package-path Tools/GlintEval DictionaryChoices \
  --cases Tools/ModelLab/eval/context_cases.json \
  --output Tools/ModelLab/results/context-choices.json

HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/ModelLab/eval/run_context_rerank.py \
  --choices-file Tools/ModelLab/results/context-choices.json
```

评估结论已落实到当前路由；完整研究记录保留在 Git 历史中。

生成候选和候选来源消融流程见
[`Tools/CandidateLab/README.md`](../CandidateLab/README.md)。候选重排结果使用
人工审阅的合成语料 gold：

```bash
python3 Tools/ModelLab/eval/run_context_rerank.py \
  --choices-file Tools/ModelLab/results/context-generated-candidates.json \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --dry-run
```

## 运行时速度与质量对照

在同一进程中加载 Hy-MT2 与 OPUS-MT，并按同一语料交错测试：

```bash
swift build --package-path Tools/GlintEval \
  --product TranslationCompare

GLINT_CT2_LIBRARY="$PWD/Resources/CTranslate2Runtime/bin/libglintct2.dylib" \
  Tools/GlintEval/.build/debug/TranslationCompare \
  --cases Tools/ModelLab/eval/cases.json \
  --mlx "$HOME/Library/Application Support/Glint/plugins/mt-hy-mt2-1.8b/model" \
  --ct2 "$PWD/Resources/OnlineModels/mt-opus-zh-en/model" \
  --metallib "$PWD/build/Build/Products/Debug/Glint.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
  --rounds 3
```

对照结果保留在 `Tools/ModelLab/results/` 和 Git 历史中。
