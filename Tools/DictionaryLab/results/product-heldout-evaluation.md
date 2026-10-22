# Product Held-Out Evaluation

- Date: 2026-10-22T03:31:58.940754+00:00
- Cases: 196
- Sources excluded from tuning: runtime overrides and M8

| Variant | Top 1 | Top 3 | Coverage | p95 |
| --- | ---: | ---: | ---: | ---: |
| dictionary_first | 46/196 (23.5%) | 69/196 (35.2%) | 69/196 | precomputed |
| qwen_context | 123/196 (62.8%) | 123/196 (62.8%) | 123/196 | 361.92ms |
| qwen_context_plus_dictionary | 123/196 (62.8%) | 134/196 (68.4%) | 134/196 | 361.92ms |
| dictionary_first_with_model_fallback | 92/196 (46.9%) | 115/196 (58.7%) | 115/196 | 80.00ms |
| hy_target_only | 88/196 (44.9%) | 88/196 (44.9%) | 88/196 | 74.08ms |
| hy_model_first_plus_dictionary | 89/196 (45.4%) | 121/196 (61.7%) | 121/196 | 74.08ms |

## Categories

| Variant | Polysemy | Business | Sentence | Control |
| --- | ---: | ---: | ---: | ---: |
| dictionary_first | 35/100 | 4/59 | 0/30 | 7/7 |
| qwen_context | 62/100 | 48/59 | 6/30 | 7/7 |
| qwen_context_plus_dictionary | 62/100 | 48/59 | 6/30 | 7/7 |
| dictionary_first_with_model_fallback | 35/100 | 42/59 | 8/30 | 7/7 |
| hy_target_only | 31/100 | 42/59 | 8/30 | 7/7 |
| hy_model_first_plus_dictionary | 32/100 | 42/59 | 8/30 | 7/7 |

