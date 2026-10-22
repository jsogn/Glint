# M20 Override Ablation

- Date: 2026-10-22
- Branch: `codex/build-dictionary-core`
- Scope: runtime override evaluation, fallback precedence, and model-first merge
- Production routing changed: yes

## 1. Decision

Do not keep general lexical overrides as the highest-priority runtime truth.
They are static answers and cannot represent context-dependent meaning.

Do not delete the complete override set yet. Top-3 evaluation shows that the
existing candidates still contain useful senses even when the static first
choice is wrong.

The stable direction is:

1. Remove 44 context-sensitive entries from runtime precedence.
2. Keep 61 stable entries as bounded ranking hints and low-priority fallbacks.
3. Put the selected model result first when it is available.
4. Preserve dictionary and curated results as additional visible candidates.
5. Keep historical expected values as tests, not runtime truth.

## 2. Why The Concern Is Valid

The audit snapshot contained 105 terms and 3 hard blocks. In the original M8
130-case regression corpus, 105 cases had the same text as an override key.
The resulting 130/130 score therefore validates the override table and routing
wiring, not generalization to unseen language.

The default translation mode remains `dictionary-first`. `model-first` remains
available, and an override never bypasses every dictionary sense.

## 3. Override Inventory

The 105 entries now have an auditable decision in
`Tools/DictionaryLab/results/override-classification.json`:

| Action | Count | Meaning |
| --- | ---: | --- |
| `retire_runtime` | 44 | Context-sensitive; no runtime precedence |
| `fallback_only` | 61 | Matching dictionary hints plus low-priority fallback |
| Exact-phrase fallbacks | 16 | Subset of fallback-only entries |

All 105 historical expected values are marked `fixture_only`. Runtime data now
stores 61 entries in `overrides` and 44 in `retiredOverrides`.

`打` and `尼` have been removed from hard blocking because both are legitimate
terms. `你号` remains in the centralized `DictionaryPolicy` invalid-fragment
rule.

## 4. Stress Corpus

`Tools/DictionaryLab/eval/override_stress_cases.json` contains 20 paired
targets, for 40 cases total. Every target is an existing override. One context
uses the sense represented by the first override value; the other requires a
different sense.

Examples:

- `落地`: product rollout versus aircraft landing.
- `发布`: product release versus social-media post.
- `问题`: software issue versus question.
- `接口`: software API versus hardware connector.
- `灰度`: canary release versus grayscale image.

References and unacceptable answers were fixed before the model run. The corpus
is adversarial: the original 50% forced-override score proved the failure mode,
while the current schema-v2 route scores 42.5%. Neither is an estimate of how
often the failure occurs in normal typing.

## 5. Results

Model: `mlx-community/Qwen3-4B-Instruct-2507-4bit`

| Variant | Top 1 | Top 3 | Conflict top 1/3 | p95 |
| --- | ---: | ---: | ---: | ---: |
| Current Swift route with schema-v2 | 17/40 (42.5%) | 32/40 (80.0%) | 6/12 | <0.1ms |
| Dictionary, no rank | 13/40 (32.5%) | 22/40 (55.0%) | 6/9 | <0.2ms |
| Dictionary + ECDICT | 17/40 (42.5%) | 27/40 (67.5%) | 4/11 | <0.2ms |
| Qwen3 4B target-only | 20/40 (50.0%) | 20/40 (50.0%) | 7/7 | 174ms |
| Qwen3 4B bounded context | 29/40 (72.5%) | 29/40 (72.5%) | 12/12 | 258ms |
| Target-only + dictionary | 20/40 (50.0%) | 32/40 (80.0%) | 7/14 | 174ms |
| Bounded context + dictionary | 29/40 (72.5%) | 34/40 (85.0%) | 12/15 | 258ms |

Against the current dictionary route, bounded context plus dictionary produced
10 top-1 pair wins, no losses, and 10 ties. The strict score is conservative: several rejected outputs
were plausible morphological variants, so 72.5% is a lower bound before semantic
audit.

Context is useful, but 8 of 20 conflict contexts still failed under strict
scoring. It is not yet reliable enough to become an unconditional replacement.

The hybrid variants performed no additional model call. They preserve the model
as the first answer and append the existing dictionary/curated candidates.
Against the current route:

- target-only hybrid: 5 top-1 pair wins, 2 losses, 13 ties; 2 top-3 pair wins,
  2 losses, 16 ties;
- context hybrid: 10 top-1 pair wins, 0 losses, 10 ties; 4 top-3 pair wins,
  2 losses, 14 ties.

### Current Production Model

The same stress set was run with the currently selected
`mlx-community/Hy-MT2-1.8B-4bit`:

| Variant | Top 1 | Top 3 | p95 |
| --- | ---: | ---: | ---: |
| Current dictionary route | 17/40 (42.5%) | 32/40 (80.0%) | <0.1ms |
| Target-only model | 17/40 (42.5%) | 17/40 (42.5%) | 53ms |
| Target-only + dictionary | 17/40 (42.5%) | 31/40 (77.5%) | 53ms |
| Bounded context + dictionary | 20/40 (50.0%) | 31/40 (77.5%) | 133ms |

For HY-MT2, bounded context regressed badly, so context remains unsupported for
this model. Target-only plus dictionary preserved top-1 and raised model-only
top-3, but the cleaned dictionary-first route reached a higher top-3 at lower
latency. New preferences therefore keep `dictionary-first` as the stable
default; an explicit `model-first` choice remains available.

### Implemented Runtime

`SmartRouter.modelFirst` now:

- keeps every model option ahead of dictionary options;
- appends dictionary/curated candidates for words and phrases;
- skips the extra dictionary lookup for classified sentences;
- returns the model result when dictionary lookup fails;
- treats an empty model result as a miss and uses the dictionary fallback.

New installs default to `dictionary-first`; an explicitly saved `model-first`
preference remains unchanged. Dictionary-first results no longer receive a
forced Override at the top. Context-sensitive values are kept only in
`retiredOverrides`, and the blocklist is centralized in `DictionaryPolicy`.

## 6. Independent Held-Out Check

The independent M18 100-case polysemy corpus has no target overlap with the
runtime overrides. Its frozen result is stored on
`codex/context-heldout-validation` at commit `96edcfd`:

| Variant | Strict polysemy accuracy |
| --- | ---: |
| Qwen3 4B target-only | 30/100 (30.0%) |
| Qwen3 4B with 24/8-character context | 59/100 (59.0%) |

This confirms that context provides a real gain, while also confirming that the
model is not accurate enough to remove all safe fallbacks. The earlier candidate
selection path reached 61/100 on the same independent corpus, still below the
90% product threshold.

Only Qwen3 4B was measured. These results do not establish that the currently
selected production model, a smaller local model, or an OpenAI-compatible
provider can replace the override path.

The 196-case M21 product held-out comparison confirms the routing decision:

| Path | Top 1 | Top 3 |
| --- | ---: | ---: |
| Dictionary-first with model fallback | 92/196 (46.9%) | 115/196 (58.7%) |
| HY-MT2 model-first + dictionary | 89/196 (45.4%) | 121/196 (61.7%) |
| Qwen3 context + dictionary | 123/196 (62.8%) | 134/196 (68.4%) |

Dictionary-first remains the default because of its higher top-1. Model-first
remains available for users who prefer broader top-3 coverage. See
`docs/M21-PRODUCT-HELDOUT.md`.

## 7. Product Implications

The current override design has two independent problems:

- correctness: a static lexical answer cannot resolve context;
- evidence quality: most regression cases reuse the same override keys.

However, replacing every override with the current model creates a different
correctness risk. The measured model quality is not high enough for that.

The safest measured sequence is:

1. Retire the 44 context-sensitive entries from runtime precedence.
2. Keep the 61 stable entries as bounded hints and low-priority fallbacks.
3. When a model result exists, make it the first visible answer.
4. Append ranked dictionary/fallback candidates without another model call.
5. Separate runtime policy rules, scoped domain corrections, and evaluation
   fixtures.
6. Build a representative held-out corpus before changing the product default.
7. Require at least 90% semantic accuracy with no control regression before
   relying on context without a dictionary fallback.

With the current HY-MT2 model, the target-only hybrid reaches 42.5% top-1 and
77.5% top-3. The Qwen3 4B context hybrid reaches 72.5% top-1 and 85% top-3.
Context remains model-selective and is not enabled for HY-MT2.

Steps 1-5 are implemented. Changing the product default and validating a
representative held-out corpus remain pending.

Removing the invalid block exposed the old schema's poor single-sense ordering.
After schema-v2 and candidate cleanup, the refreshed M8 baseline is 74.2% top-1
and 89.1% top-3. Dictionary ranking is improved but still not strong enough to compete
with context on ambiguous cases.

## 8. Reproduce

```bash
python3 -m unittest discover -s Tools/DictionaryLab -p 'test_*.py' -v
swift test --package-path Packages/GlintCore
python3 Tools/DictionaryLab/audit_runtime_overrides.py
swift run --package-path Tools/GlintEval DictionaryChoices \
  --cases Tools/DictionaryLab/eval/current_route_cases.json \
  --wiktionary-db \
  "$HOME/Library/Application Support/Glint/plugins/dict-wiktionary-zh-en/dictionary.sqlite3" \
  --output Tools/DictionaryLab/results/current-route-choices.json
python3 Tools/DictionaryLab/evaluate_override_ablation.py --dry-run
HF_HUB_OFFLINE=1 Tools/ModelLab/.venv/bin/python \
  Tools/DictionaryLab/evaluate_override_ablation.py
```

Artifacts:

- Corpus:
  `Tools/DictionaryLab/eval/override_stress_cases.json`
- Runner:
  `Tools/DictionaryLab/evaluate_override_ablation.py`
- Classification:
  `Tools/DictionaryLab/results/override-classification.json`
- Current Swift choices:
  `Tools/DictionaryLab/results/current-route-choices.json`
- Raw results:
  `Tools/DictionaryLab/results/override-ablation.json`
- Summary:
  `Tools/DictionaryLab/results/override-ablation.md`

## 9. Validation

- `swift test --package-path Packages/GlintCore`: 42 tests passed.
- `./scripts/test.sh`: full workspace suite passed.
- `GlintBenchmark`: 95/128 top-1, 114/128 top-3, one expected blocked
  fragment, p95 under 2ms.
- `./scripts/dev.sh`: stable-signed Debug app built and started one instance.
- Active local preference during validation: `modelFirst` with
  `mt-hy-mt2-1.8b`.
- Removed development-only compatibility paths for CC-CEDICT schema-v1,
  OpenAI single-provider migration, and the retired stability-delay key.

The signed App launch and runtime readiness were verified. HUD output for a
live candidate was not manually exercised in this pass.
