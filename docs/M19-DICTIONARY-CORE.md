# M19 Dictionary Core Audit

- Date: 2026-10-22
- Branch: `codex/build-dictionary-core`
- Scope: dictionary schema audit, benchmark, and production integration
- Product routing changed: yes

## 1. Decision

Keep the dictionary as a permanent Glint capability.

The previous production implementation could not be kept unchanged. It lost
source polysemy before ranking. CC-CEDICT now uses schema-v2: every source sense
and reading is stored, while the runtime returns a bounded ranked candidate
list for the HUD.

The target architecture is:

1. Normalized, source-attributed sense index.
2. Curated high-confidence overrides.
3. ECDICT frequency and quality ranking.
4. Model fallback for missing or natural-language cases.
5. Later, optional context selection over the preserved sense inventory.

Model-first is now the default for new preferences.

## 2. Pre-Schema-V2 Audit

Production CC-CEDICT:

- Schema: `entries(word TEXT PRIMARY KEY, gloss TEXT NOT NULL)`.
- Rows: 183,662.
- Distinct words: 183,662.
- Consequence: equal headwords overwrite each other by construction.

Concrete losses in the installed database:

- 打: one row, gloss `dozen (loanword)`.
- 看: one row and one reading, primarily `look after / take care of / watch`.
- 方便: `instant` is absent.
- 长短: `pros and cons` is absent.

ECDICT:

- 152,449 ranking rows across 101,755 terms.
- Useful for frequency, Collins and Oxford signals.
- Not a complete Chinese sense inventory by itself.

Wiktionary:

- 223,203 source rows across 168,530 distinct Chinese targets.
- Preserves more senses and parts of speech.
- Its source ordering is inconsistent and still needs ranking.

## 3. Normalized Index Prototype

Source preservation:

| Source | Stored senses |
| --- | ---: |
| CC-CEDICT | 199,687 |
| Wiktionary | 227,203 |
| **Total** | **426,890** |

The prototype has:

- 211,015 distinct headwords.
- 152,449 ECDICT ranking rows.
- About 69MB uncompressed SQLite.

Examples:

- 打: 12 normalized rows and two pinyin readings.
- 看: 21 rows and two pinyin readings.
- 方便: CC-CEDICT and Wiktionary senses retained separately.
- 味道: food, feeling, hint, interest and other senses remain separate.

### Schema

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

Indexes cover simplified/traditional headwords, source priority, source order,
and frequency. `headword` deliberately has no unique constraint.

ECDICT remains a separate `rankings` table. Ranking can change display order,
but it cannot delete a sense.

### Packaged CC-CEDICT v2

The shipped CC-CEDICT plugin now uses the same preservation rule without
duplicating other installed dictionary sources:

```sql
CREATE TABLE entries (
    sense_id INTEGER PRIMARY KEY,
    simplified TEXT NOT NULL,
    traditional TEXT NOT NULL,
    pinyin TEXT NOT NULL,
    gloss TEXT NOT NULL,
    line_order INTEGER NOT NULL,
    sense_order INTEGER NOT NULL
);
```

The packaged database contains 125,109 source entries and 199,687 senses in a
23.6MB SQLite file. `word` is no longer a primary key. The adapter reads up to
64 senses, ranks candidates, and exposes only the normal HUD subset.

The adapter supports only this schema. If a v2 query cannot be prepared, the
dictionary falls back to curated/builtin paths rather than crashing; there is no
old-schema compatibility branch.

## 4. Benchmark

The benchmark uses:

- 120 targets from the existing context corpus with expected reference senses.
- The 128-case dictionary regression corpus.
- Current CC-CEDICT and three normalized variants.
- Direct SQLite lookup from Python; App lifecycle is not included.

### Context Corpus

| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Production router, precomputed | 35.8% | 28.3% | 35.8% | 31.1% | n/a |
| Current CC-CEDICT | 20.8% | 12.5% | 20.8% | 17.4% | 0.40ms |
| Normalized CC-CEDICT | 35.8% | 15.0% | 25.8% | 29.9% | 0.74ms |
| Normalized CC-CEDICT + Wiktionary | 43.3% | 15.0% | 26.7% | 36.8% | 0.22ms |
| Normalized union + ECDICT rank | 43.3% | 11.7% | 21.7% | 36.8% | 0.40ms |

On the 80 polysemy targets:

- Current CC-CEDICT coverage: 22.5%.
- Normalized union coverage: 53.8%.
- Correct-sense availability more than doubles.

Raw dictionary top-1 remains low because context is absent. The ECDICT-ranked
variant is worse on this context benchmark because it prioritizes globally
frequent senses, not the context-specific sense. Ranking must therefore be
applied only to the no-context fallback or after a context sense is selected.

### Regression Corpus

| Variant | Coverage | Top 1 | Top 3 | Reference recall | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Current CC-CEDICT | 59.8% | 41.7% | 59.8% | 56.2% | 0.26ms |
| Normalized CC-CEDICT | 67.7% | 44.1% | 63.8% | 65.2% | 0.45ms |
| Normalized union | 74.0% | 44.1% | 65.4% | 71.3% | 0.08ms |
| Normalized union + ECDICT rank | 74.0% | 54.3% | 70.1% | 71.3% | 0.28ms |

ECDICT ranking raises first-choice regression accuracy from 44.1% to 54.3%.
After M20 removed forced Override precedence, the production guardrail baseline
was 83/128 top-1 and 102/128 top-3. Schema-v2 and shared surface normalization
raised that to 95/128 top-1 and 114/128 top-3. This confirms that preserving senses helps materially, while
open dictionary ranking alone is still not sufficient for product-quality
first choices.

## 5. Conclusions

- The dictionary is valuable and should be retained.
- The current database schema is the main source of lost polysemy, not the
  dictionary concept itself.
- Preserving all source senses materially improves ambiguity coverage.
- Wiktionary adds useful coverage but also noise.
- ECDICT is valuable for no-context ordering, not for choosing context-specific
  senses.
- Curated overrides remain a required high-confidence layer.
- Dictionary lookup itself is sub-millisecond in the measured SQLite workloads;
  ranking and model fallback are the meaningful quality/cost decisions.
- Dictionary coverage alone cannot guarantee accurate translation because the
  unresolvable problem is sense selection.

## 6. Next Work

Completed:

- schema-v2 product index with preserved senses and pinyin;
- bounded sense adapter;
- shared surface normalization across all dictionary plugins;
- low-priority curated fallback;
- model-first routing with dictionary alternatives;
- benchmark coverage for sense retention, top-1, top-3, and latency.

Remaining:

1. Improve no-context ranking for source order, phrase shape, and grammatical
   role. The selected candidate's pinyin is not exposed by Accessibility and
   cannot currently be used for runtime filtering.
2. Measure schema-v2 with the representative product corpus rather than only
   the adversarial stress set.
3. Continue context work only for models that demonstrated a held-out gain.

## 7. Artifacts

- Production builder: `Tools/DictionaryBuilder/build_sqlite.py`
- Builder: `Tools/DictionaryLab/build_normalized_lexicon.py`
- Benchmark: `Tools/DictionaryLab/benchmark_lexicon.py`
- Tests: `Tools/DictionaryLab/test_*.py`
- Results: `Tools/DictionaryLab/results/dictionary-core-benchmark.json`
- Markdown summary:
  `Tools/DictionaryLab/results/dictionary-core-benchmark.md`
