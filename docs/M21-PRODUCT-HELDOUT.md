# M21 Product Held-Out Validation

- Date: 2026-10-22
- Scope: independent product-path validation
- Production routing changed during this study: no

## 1. Corpus

The source is the M18 200-case held-out corpus at commit `96edcfd`.

Targets overlapping either the runtime override inventory or the M8 regression
corpus were removed before evaluation:

- `学生`
- `苹果`
- `谢谢`
- `里程碑`

The final product set contains 196 cases:

- 100 polysemy cases;
- 59 business/technical cases;
- 30 sentence cases;
- 7 control cases.

The corpus was not used to tune the dictionary surface rules, ranking, or model
prompts in this study.

## 2. Results

| Path | Top 1 | Top 3 | p95 |
| --- | ---: | ---: | ---: |
| Dictionary-first with model fallback | 92/196 (46.9%) | 115/196 (58.7%) | 80ms |
| HY-MT2 target-only | 88/196 (44.9%) | 88/196 (44.9%) | 74ms |
| HY-MT2 model-first + dictionary | 89/196 (45.4%) | 121/196 (61.7%) | 74ms |
| Qwen3 4B context | 123/196 (62.8%) | 123/196 (62.8%) | 362ms |
| Qwen3 4B context + dictionary | 123/196 (62.8%) | 134/196 (68.4%) | 362ms |

Category top-1:

| Path | Polysemy | Business | Sentence | Control |
| --- | ---: | ---: | ---: | ---: |
| Dictionary-first fallback | 35/100 | 42/59 | 8/30 | 7/7 |
| HY-MT2 model-first + dictionary | 32/100 | 42/59 | 8/30 | 7/7 |
| Qwen3 context + dictionary | 62/100 | 48/59 | 6/30 | 7/7 |

Qwen sentence accuracy is lower than HY-MT2 on this set; stronger context
polysemy accuracy does not imply better short-sentence translation.

## 3. Decision

- Keep `dictionary-first` as the default for new preferences. Its real fallback
  path has slightly higher top-1 than HY-MT2 model-first.
- Preserve an explicitly selected `model-first` preference. It improves top-3
  by 3 points on this corpus and may better match personal quality preferences.
- Do not enable context automatically. It remains model-selective, slower, and
  only reaches 62.8% top-1 on the independent set.
- Do not relax the 90% quality gate. The current system still fails roughly one
  ambiguous case in three without context.
- Stop adding dictionary sources. The remaining bottleneck is sense selection,
  not missing headwords.

## 4. Artifacts

- Cases: `Tools/DictionaryLab/eval/product_heldout_cases.json`
- Route choices:
  `Tools/DictionaryLab/results/product-heldout-route-choices.json`
- Evaluator: `Tools/DictionaryLab/evaluate_product_heldout.py`
- Results:
  `Tools/DictionaryLab/results/product-heldout-evaluation.{json,md}`
