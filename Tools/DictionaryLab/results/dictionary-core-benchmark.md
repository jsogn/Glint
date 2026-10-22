# Dictionary Core Benchmark

- Date: 2026-10-22T03:07:09.204382+00:00
- Normalized lexicon: `build/dictionary-core/normalized_lexicon.sqlite3`

## Context Corpus

| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| production_router | 35.8% | 28.3% | 35.8% | 31.1% | precomputed |
| current_cedict | 20.8% | 12.5% | 20.8% | 17.4% | 0.0180ms |
| normalized_cedict | 35.8% | 15.0% | 25.8% | 29.9% | 0.6055ms |
| normalized_union | 43.3% | 15.0% | 26.7% | 36.8% | 0.2470ms |
| normalized_ranked_union | 43.3% | 11.7% | 21.7% | 36.8% | 0.4280ms |

## Regression Corpus

| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| current_cedict | 59.8% | 41.7% | 59.8% | 56.2% | 0.0172ms |
| normalized_cedict | 67.7% | 44.1% | 63.8% | 65.2% | 0.3852ms |
| normalized_union | 74.0% | 44.1% | 65.4% | 71.3% | 0.0829ms |
| normalized_ranked_union | 74.0% | 54.3% | 70.1% | 71.3% | 0.3255ms |
