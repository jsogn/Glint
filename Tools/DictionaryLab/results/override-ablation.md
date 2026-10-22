# Override Ablation

- Date: 2026-10-22T03:25:38.995687+00:00
- Model: `mlx-community/Qwen3-4B-Instruct-2507-4bit`
- Cases: 40 (20 paired targets)
- Corpus: adversarial override stress set

| Variant | Top 1 | Top 3 | Aligned 1/3 | Conflict 1/3 | Both in pair 1/3 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| current_override | 17/40 (42.5%) | 32/40 (80.0%) | 11/20 | 6/20 / 12 | 1/20 / 12 | 0.0002ms |
| dictionary_unranked | 13/40 (32.5%) | 22/40 (55.0%) | 7/20 | 6/20 / 9 | 1/20 / 7 | 0.0923ms |
| dictionary_ranked | 17/40 (42.5%) | 27/40 (67.5%) | 13/20 | 4/20 / 11 | 1/20 / 9 | 0.1072ms |
| model_target_only | 20/40 (50.0%) | 20/40 (50.0%) | 13/20 | 7/20 / 7 | 3/20 / 3 | 174.2922ms |
| model_context | 29/40 (72.5%) | 29/40 (72.5%) | 17/20 | 12/20 / 12 | 9/20 / 9 | 257.7091ms |
| model_target_only_plus_dictionary | 20/40 (50.0%) | 32/40 (80.0%) | 13/20 | 7/20 / 14 | 3/20 / 12 | 174.2922ms |
| model_context_plus_dictionary | 29/40 (72.5%) | 34/40 (85.0%) | 17/20 | 12/20 / 15 | 9/20 / 14 | 257.7091ms |

## Paired Comparison vs Current Override

| Variant | Top-1 pair W/L/T | Top-3 pair W/L/T |
| --- | ---: | ---: |
| dictionary_unranked | 2/5/13 | 0/8/12 |
| dictionary_ranked | 1/1/18 | 0/5/15 |
| model_target_only | 5/2/13 | 2/12/6 |
| model_context | 10/0/10 | 4/7/9 |
| model_target_only_plus_dictionary | 5/2/13 | 2/2/16 |
| model_context_plus_dictionary | 10/0/10 | 4/2/14 |

