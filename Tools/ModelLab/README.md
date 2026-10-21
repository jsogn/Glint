# Glint ModelLab

M1 模型实验区。这里只做模型对比，不进入 App 安装包。

**M1 已完成**：结果见 [`docs/M1-MODEL-SPIKE.md`](../../docs/M1-MODEL-SPIKE.md)。

## 目标

对比：

- OPUS-MT zh-en（轻量默认候选）
- M2M100-418M（均衡候选）
- Qwen3-4B 4-bit（高质量候选）

## 测试集

`eval/cases.sample.json` 是初始样本；M1 正式评测扩展到 50 条，覆盖：

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

- `docs/M1-MODEL-SPIKE.md`
- `Tools/ModelLab/results/` 下的原始结果

## 约束

- Python 只用于实验和模型转换；
- 不把 Python 或模型文件放进 App；
- 不把模型下载逻辑写进 App，直到 M1 选出运行时。

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

评估结论见
[`docs/M16-CONTEXT-EVALUATION.md`](../../docs/M16-CONTEXT-EVALUATION.md)
和
[`docs/M17-CONTEXT-DISAMBIGUATION-RESEARCH.md`](../../docs/M17-CONTEXT-DISAMBIGUATION-RESEARCH.md)。

M17 的生成候选和候选来源消融流程见
[`Tools/CandidateLab/README.md`](../CandidateLab/README.md)。候选重排结果使用
人工审阅的合成语料 gold：

```bash
python3 Tools/ModelLab/eval/run_context_rerank.py \
  --choices-file Tools/ModelLab/results/context-generated-candidates.json \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --dry-run
```
