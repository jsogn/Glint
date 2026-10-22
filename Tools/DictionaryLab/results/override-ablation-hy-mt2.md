# Override Ablation

- Date: 2026-10-22T03:25:00.969140+00:00
- Model: `mlx-community/Hy-MT2-1.8B-4bit`
- Cases: 40 (20 paired targets)
- Corpus: adversarial override stress set

| Variant | Top 1 | Top 3 | Aligned 1/3 | Conflict 1/3 | Both in pair 1/3 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| current_override | 17/40 (42.5%) | 32/40 (80.0%) | 11/20 | 6/20 / 12 | 1/20 / 12 | 0.0003ms |
| dictionary_unranked | 13/40 (32.5%) | 22/40 (55.0%) | 7/20 | 6/20 / 9 | 1/20 / 7 | 0.0915ms |
| dictionary_ranked | 17/40 (42.5%) | 27/40 (67.5%) | 13/20 | 4/20 / 11 | 1/20 / 9 | 0.1099ms |
| model_target_only | 17/40 (42.5%) | 17/40 (42.5%) | 11/20 | 6/20 / 6 | 2/20 / 2 | 53.2451ms |
| model_context | 7/40 (17.5%) | 7/40 (17.5%) | 2/20 | 5/20 / 5 | 1/20 / 1 | 132.7003ms |
| model_target_only_plus_dictionary | 17/40 (42.5%) | 31/40 (77.5%) | 11/20 | 6/20 / 14 | 2/20 / 12 | 53.2451ms |
| model_context_plus_dictionary | 20/40 (50.0%) | 31/40 (77.5%) | 12/20 | 8/20 / 13 | 5/20 / 11 | 132.7003ms |

## Paired Comparison vs Current Override

| Variant | Top-1 pair W/L/T | Top-3 pair W/L/T |
| --- | ---: | ---: |
| dictionary_unranked | 2/5/13 | 0/8/12 |
| dictionary_ranked | 1/1/18 | 0/5/15 |
| model_target_only | 3/4/13 | 1/14/5 |
| model_context | 1/12/7 | 1/19/0 |
| model_target_only_plus_dictionary | 3/4/13 | 2/3/15 |
| model_context_plus_dictionary | 4/2/14 | 1/2/17 |

