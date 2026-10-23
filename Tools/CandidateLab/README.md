# Glint Candidate Lab

Research-only builder for a context-disambiguation candidate bank.

The bank preserves homographs and multiple dictionary senses. It is not loaded
by the App and does not change the production dictionary or routing behavior.

## Sources

- CC-CEDICT raw dictionary: https://cc-cedict.org/
- ECDICT rank SQLite: https://github.com/skywind3000/ECDICT
- Wiktionary / Kaikki SQLite: https://kaikki.org/dictionary/Chinese/
- Glint curated overrides

Source licenses and distribution constraints are recorded in
`docs/DICTIONARY-SOURCES.md`.

## Build

Download the raw CC-CEDICT archive outside the repository:

```bash
curl -L --fail \
  https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  -o /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz
```

Build the research bank:

```bash
python3 Tools/CandidateLab/build_candidate_bank.py \
  --cedict-gz /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  --ecdict-db "$HOME/Library/Application Support/Glint/plugins/dict-ecdict/ecdict_rank.sqlite3" \
  --wiktionary-db "$HOME/Library/Application Support/Glint/plugins/dict-wiktionary-zh-en/dictionary.sqlite3" \
  --overrides "$HOME/Library/Application Support/Glint/plugins/dict-cedict/overrides.json" \
  --cases Tools/ModelLab/eval/context_cases.json \
  --output Tools/ModelLab/results/context-candidate-bank.json
```

The output can be supplied directly to the context reranking evaluator:

```bash
python3 Tools/ModelLab/eval/run_context_rerank.py \
  --choices-file Tools/ModelLab/results/context-candidate-bank.json \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --dry-run
```

## Generated candidates

The current research pipeline uses context-specific candidates from Qwen3 4B.
Each prompt requests three candidates. Candidate counts above three reduced
coverage and increased noise in evaluation.

```bash
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/CandidateLab/generate_context_candidates.py \
  --model-id mlx-community/Qwen3-4B-Instruct-2507-4bit \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --output Tools/ModelLab/results/context-generated-candidates.json
```

Merge dictionary and generated candidates while retaining manual gold metrics:

```bash
python3 Tools/CandidateLab/merge_candidate_sources.py \
  --bank Tools/ModelLab/results/context-candidate-bank.json \
  --generated Tools/ModelLab/results/context-generated-candidates.json \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --output Tools/ModelLab/results/context-candidate-bank-merged.json
```

Run the best measured quality path. The selector outputs only one option letter:

```bash
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/ModelLab/eval/run_context_rerank.py \
  --model-id mlx-community/Qwen3-4B-Instruct-2507-4bit \
  --choices-file Tools/ModelLab/results/context-generated-candidates.json \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --output Tools/ModelLab/results/context-ablation-generated-qwen3-4b.json
```

To evaluate the lower-latency one-generation path:

```bash
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/ModelLab/eval/run_context_rerank.py \
  --model-id mlx-community/Qwen3-4B-Instruct-2507-4bit \
  --choices-file Tools/ModelLab/results/context-generated-candidates.json \
  --generation-prompt compound_aware \
  --fallback-generation-prompt direct \
  --gold-file Tools/ModelLab/eval/context_choice_gold.json \
  --output Tools/ModelLab/results/context-ablation-compound-qwen3-4b.json
```

The evaluated context-dictionary merge reduced answer coverage, added
distractors, and did not improve top-choice accuracy, so it is not part of the
production pipeline.
