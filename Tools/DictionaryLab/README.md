# Glint Dictionary Lab

Research tooling for preserving dictionary polysemy and evaluating the
dictionary core. Runtime decisions have been applied to the current routing.

## Build

The raw CC-CEDICT archive is not stored in the repository:

```bash
curl -L --fail \
  https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  -o /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz
```

Build the normalized research lexicon:

```bash
python3 Tools/DictionaryLab/build_normalized_lexicon.py \
  --cedict-gz /tmp/cedict_1_0_ts_utf-8_mdbg.txt.gz \
  --wiktionary-db "$HOME/Library/Application Support/Glint/plugins/dict-wiktionary-zh-en/dictionary.sqlite3" \
  --ecdict-db "$HOME/Library/Application Support/Glint/plugins/dict-ecdict/ecdict_rank.sqlite3" \
  --output build/dictionary-core/normalized_lexicon.sqlite3
```

## Benchmark

```bash
python3 Tools/DictionaryLab/benchmark_lexicon.py \
  --lexicon build/dictionary-core/normalized_lexicon.sqlite3 \
  --current-cedict "$HOME/Library/Application Support/Glint/plugins/dict-cedict/cedict.sqlite3" \
  --output Tools/DictionaryLab/results/dictionary-core-benchmark.json
```

The benchmark covers:

- 120 context-corpus targets with expected reference senses.
- The 128-case dictionary regression corpus.
- Raw CC-CEDICT, normalized CC-CEDICT, normalized union, and
  ECDICT-ranked union.

## Schema

`lexicon_entries` stores one row per source sense. A headword is intentionally
not unique:

```sql
CREATE TABLE lexicon_entries (
    sense_id INTEGER PRIMARY KEY,
    headword TEXT NOT NULL,
    traditional TEXT NOT NULL,
    pinyin TEXT,
    definition TEXT NOT NULL,
    part_of_speech TEXT,
    source TEXT NOT NULL,
    source_priority INTEGER NOT NULL,
    source_order INTEGER NOT NULL,
    sense_order INTEGER NOT NULL,
    frequency INTEGER
);
```

`rankings` stores ECDICT frequency and dictionary-quality signals. Rankings are
applied after sense preservation; they never collapse or discard a source
sense.

## Tests

```bash
python3 -m unittest discover -s Tools/DictionaryLab -p 'test_*.py' -v
```

## Override Ablation

The override stress corpus contains 20 paired targets. Each target appears in
one context aligned with the current first override and one context that
requires a different sense. It is deliberately adversarial and must not be
treated as a frequency estimate for the full product.

Runtime `overrides.json` now has two sections:

- `overrides`: stable hints and exact low-priority fallback candidates;
- `retiredOverrides`: context-sensitive historical candidates that can only
  appear after dictionary results.

Generate the auditable runtime classification and current Swift candidates:

```bash
python3 Tools/DictionaryLab/audit_runtime_overrides.py
swift run --package-path Tools/GlintEval DictionaryChoices \
  --cases Tools/DictionaryLab/eval/current_route_cases.json \
  --wiktionary-db \
  "$HOME/Library/Application Support/Glint/plugins/dict-wiktionary-zh-en/dictionary.sqlite3" \
  --output Tools/DictionaryLab/results/current-route-choices.json
```

Validate the corpus and run the dictionary-only baselines:

```bash
python3 Tools/DictionaryLab/evaluate_override_ablation.py --dry-run
python3 Tools/DictionaryLab/evaluate_override_ablation.py --skip-model
```

Run the same target-only and bounded-context Qwen3 4B comparison as the context
research:

```bash
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/DictionaryLab/evaluate_override_ablation.py
```

The default report is
`Tools/DictionaryLab/results/override-ablation.{json,md}`.

## Product Held-Out

The 196-case product set excludes every target used by runtime overrides or the
M8 dictionary corpus. It compares the real dictionary fallback route, the
selected HY-MT2 model-first route, and the frozen Qwen3 context upper bound:

```bash
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/DictionaryLab/evaluate_product_heldout.py
```

Output:
`Tools/DictionaryLab/results/product-heldout-evaluation.{json,md}`.
