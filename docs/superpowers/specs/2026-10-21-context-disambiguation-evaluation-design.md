# Context Disambiguation Evaluation Design

- Date: 2026-10-21
- Branch: `codex/evaluate-context-disambiguation`
- Status: approved for evaluation implementation
- Scope: measure whether bounded AX context improves the current model-first
  translation path before considering a product integration

## 1. Objective

Determine whether local context improves translation quality enough to justify:

- reading bounded text around the active IME composition;
- a privacy-policy and permission-surface change;
- additional AX calls and context tokens;
- more complex routing and cache invalidation.

The first phase evaluates the existing model-first configuration with
`mt-hy-mt2-1.8b`. It does not change the production monitoring or translation
path.

## 2. Questions

1. Does curated context improve ambiguous words and phrases?
2. Is preceding context alone sufficient, or does following context add value?
3. Is a 24-character context window sufficient, or is 48 characters materially
   better?
4. Does context introduce regressions on unambiguous words or sentences?
5. How much does context increase Hy-MT2 latency?
6. Which macOS text controls expose a safe, bounded AX range API?

## 3. Non-Goals

- Do not enable context in the shipping App.
- Do not OCR screenshots.
- Do not read complete `AXValue` strings in the evaluation runner.
- Do not send context to OpenAI-compatible providers.
- Do not change the default dictionary/model route.
- Do not evaluate dictionary reranking in phase one. That becomes a follow-up
  experiment only if raw model context shows measurable value.
- Do not collect real user text.

## 4. Evaluation Corpus

Create `Tools/ModelLab/eval/context_cases.json` with 120 synthetic cases:

- 40 ambiguous targets, each evaluated in two different contexts: 80 cases.
- 15 technical or business targets with context: 15 cases.
- 15 sentence or tone-sensitive cases: 15 cases.
- 10 no-context controls: 10 cases.

Each paired target must use the same Chinese candidate in both contexts. The
expected translations must differ when the context changes the meaning.

Schema:

```json
{
  "id": "amb-001-a",
  "pair_id": "amb-001",
  "kind": "word",
  "target": "打",
  "before": "我想",
  "after": "车去公司",
  "references": ["take a taxi"],
  "unacceptable": ["hit", "beat"],
  "category": "polysemy"
}
```

Requirements:

- The target is never inferred from context. It is supplied explicitly.
- `references` contains acceptable translations, not only one exact wording.
- `before` and `after` contain only synthetic test text.
- Cases must cover Chinese punctuation, ASCII punctuation, emoji-adjacent text,
  sentence starts, sentence middles, and sentence ends.

## 5. Context Variants

Every case runs through four prompts with one model load:

- `m0`: target only, matching current model-first behavior.
- `m1`: target plus up to 24 characters before it.
- `m2`: target plus up to 24 characters before and 8 after it.
- `m3`: target plus up to 48 characters before and 8 after it.

Context is truncated at a Unicode-safe boundary. The prompt instructs the model
to translate only the target and use surrounding text strictly for
disambiguation.

The four variants use the same model, prompt template, decoding settings, and
case order. Cache is disabled during the primary quality run.

## 6. Model and Runtime

- Primary model: `mlx-community/Hy-MT2-1.8B-4bit`.
- Primary result must come from the same MLX runtime semantics used by the App.
- Python ModelLab may drive the first pass because it already loads MLX models,
  but any positive result must be confirmed through the Swift
  `MLXTranslationEngine` before product work.
- OPUS-MT is optional only as a latency/quality sanity check and cannot override
  a Hy-MT2 decision.
- The report records model ID, prompt profile, seed or decoding settings,
  load time, RSS, and context length.

## 7. Scoring

Each output is classified as:

- `acceptable`: normalized text matches one entry in `references`.
- `incorrect`: output is valid English but not acceptable.
- `invalid`: empty, Chinese, explanatory, quoted, multi-paragraph, or context
  leakage.
- `error`: model/runtime exception.

Normalization:

- Unicode NFKC;
- lowercase;
- trim whitespace;
- collapse repeated whitespace;
- remove terminal punctuation only;
- preserve semantic contractions and articles.

Strict exact match remains a diagnostic metric but is not the primary quality
gate. Manual review is required for outputs that are semantically close but not
listed in `references`.

## 8. Metrics

The report includes:

- acceptable accuracy overall;
- accuracy for ambiguous pairs, business terms, sentences, and controls;
- paired win/loss/tie count against `m0`;
- invalid/error rate;
- context leakage count;
- p50 and p95 inference latency;
- p50 and p95 input token count;
- context window availability in the AX probe.

Paired comparisons are primary. Aggregate accuracy alone can hide regressions.

## 9. Decision Gates

Context proceeds to a production design only if all conditions hold:

- ambiguous-set acceptable accuracy improves by at least 10 percentage points;
- overall acceptable accuracy improves by at least 3 percentage points;
- no control category regresses by more than 2 percentage points;
- invalid/error rate does not increase;
- Hy-MT2 p95 inference latency increases by no more than 20ms;
- the 24-character window retains at least 80% of the 48-character improvement;
- AX bounded range extraction works in TextEdit and Chrome for the synthetic
  fixture.

If only paired ambiguous cases improve but controls regress, the result is
partial and requires a context-gated routing design. If no gate is met, stop
the context effort and retain candidate-only translation.

## 10. AX Feasibility Probe

Extend tool-only probe coverage without modifying `MonitoringController`.

For TextEdit, Chrome, and Safari:

- locate the focused editable element;
- read role, selected range, marked range, and character count;
- query parameterized attribute names;
- call `AXStringForRange` for the configured window only;
- never call parameterized APIs for an unbounded full document;
- record whether context is available, partial, or unavailable.

The probe uses fixed synthetic text and never records unrelated field content.

## 11. Components

- `Tools/ModelLab/eval/context_cases.json`: paired corpus.
- `Tools/ModelLab/eval/run_context_eval.py`: model variants, scoring, JSON and
  Markdown output.
- `Tools/ModelLab/results/context-*.json`: raw results.
- `docs/M16-CONTEXT-EVALUATION.md`: conclusions and decision.
- Tool-only AX probe addition: capability matrix for bounded context.

The production `SmartRouter`, `TranslationMemo`, and `MonitoringController` are
unchanged in this phase.

## 12. Error Handling

- A malformed case fails the runner before model load.
- A model exception is recorded against that variant/case and does not stop the
  remaining cases.
- Missing context falls back to `m0` wording, not an empty prompt.
- Any report containing real user text is invalid and must not be committed.

## 13. Testing

- Unit tests for context clipping, Unicode boundaries, prompt construction, and
  normalization.
- Golden test for one paired polysemy case.
- Dataset validation checks unique IDs and complete `pair_id` pairs.
- Dry-run mode validates the corpus without loading a model.
- Model smoke test uses one pair before the full run.

## 14. Deliverables

1. Validated synthetic corpus.
2. Context evaluation runner with dry-run and smoke-test modes.
3. Hy-MT2 results for `m0` through `m3`.
4. AX capability report for TextEdit, Chrome, and Safari.
5. `docs/M16-CONTEXT-EVALUATION.md` with a go/no-go decision.

No production integration is allowed until this report passes the decision
gates and a separate implementation design is approved.
