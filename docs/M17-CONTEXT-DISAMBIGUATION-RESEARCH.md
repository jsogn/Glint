# M17 Context Disambiguation Research

- Date: 2026-10-21
- Branch: `codex/evaluate-context-disambiguation`
- Scope: synthetic candidate disambiguation research only
- Context routing behavior changed during research: no
- Follow-up cleanup: inactive OCR, screenshot, and Screen Recording code paths
  were removed after this study confirmed context does not need OCR

## 1. Decision

Context is worth continuing as a **model-selective, opt-in high-quality mode**,
but it is not ready to become the default translation path.

The strongest measured design is:

1. Read 24 characters before and 8 characters after the focused caret with
   Accessibility.
2. Ask Qwen3 4B for direct and compound-aware English candidates.
3. Ask Qwen3 4B again to select one option by letter.
4. Do not merge production dictionary candidates into this path.
5. Fall back to ordinary target-only translation when AX context is unavailable.

This path reached 77/80 acceptable polysemy translations (96.25%) in the
current synthetic set. It took about 939ms p50 and 1071ms p95 end-to-end,
including two generation calls and one selection call.

The lower-latency one-generation path reached 75/80 (93.75%) with about 626ms
p50 and 702ms p95. It is the better first integration candidate if a roughly
0.7-second HUD update is acceptable.

Do not remove the dictionary globally based on this report. The evidence
supports bypassing the dictionary **inside contextual Qwen3 4B mode**. The
ordinary target-only path has not been re-evaluated with a held-out corpus, and
the current 80-case result used manually reviewed gold choices.

## 2. What Was Determined

- A translation model normally emits one generated sequence. It does not
  expose a cross-sense candidate ranking.
- Glint currently wraps that one sequence as a single
  `TranslationResult` option. The fixed `0.92` confidence is not a calibrated
  probability.
- MLX greedy decoding has token probabilities internally, but those are not
  semantic sense probabilities. Beam search in the OPUS-MT bridge also does not
  expose production-quality sense confidence.
- Context meaningfully improves polysemy decisions, but only Qwen3 4B and
  Index-Translate 2B produced usable raw contextual translations in this
  matrix.
- Candidate generation followed by context selection is substantially stronger
  than raw contextual translation for Qwen3 4B.
- The dictionary is not a good candidate source for this path. It has low
  ambiguity coverage and adds distractors without improving final accuracy.
- macOS Accessibility can provide bounded current-control context without OCR
  in TextEdit, Chrome, and Safari. OCR is unnecessary for these controls and
  should not be used as an automatic fallback.

## 3. Corpus And Scoring

`Tools/ModelLab/eval/context_cases.json` contains 120 synthetic cases:

- 80 polysemy cases: 40 targets, each in two contexts.
- 15 business and technical phrases.
- 15 short responses.
- 10 no-context controls.

The polysemy comparison uses `context_choice_gold.json`. It contains manually
reviewed acceptable candidate surfaces for each context. Surface normalization
removes list markers, leading option labels, punctuation differences, leading
parenthetical qualifiers, and redundant `to`.

This is stricter than accepting any semantically plausible free text: an answer
must be one of the supplied candidate options and belong to that case's gold
set. It is also broader than exact reference-string matching because valid
synonyms such as `deployed` for 落地 and `looks after` for 带孩子 are accepted.

Important limitation: the gold set was reviewed after examining the candidate
bank. The absolute rate is therefore not an independent held-out result. The
candidate-source comparison remains useful because every source is scored
against the same gold set.

## 4. Raw Context Translation

These rates use the 80 polysemy cases and the same semantic gold set. `m2`
supplies 24 preceding and 8 following characters.

| Model | No context | With context | Invalid in `m2` | p95 no context | p95 context |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hy-MT2 1.8B | 26.2% | 12.5% | 65/80 | 71.84ms | 135.72ms |
| Qwen3 0.6B | 26.2% | 8.8% | 60/80 | 40.02ms | 49.39ms |
| Qwen3 1.7B | 23.8% | 2.5% | 78/80 | 80.22ms | 111.79ms |
| Qwen3 4B | 28.7% | 71.2% | 0/80 | 176.60ms | 283.38ms |
| Index-Translate 2B | 28.7% | 53.8% | 1/80 | 50.99ms | 129.69ms |

Only Qwen3 4B and Index-Translate 2B combine useful context gains with reliable
target-only output. The smaller instruction models frequently translate the
whole sentence or emit Chinese.

## 5. Candidate Pipeline

Qwen3 4B generated candidates with two prompts:

- Direct: use the marked sentence and propose three target translations.
- Compound-aware: first identify a possible compound containing the target,
  then propose three translations.

Generation quality on the 80 polysemy cases:

| Metric | Result |
| --- | ---: |
| At least one gold candidate available | 79/80 |
| Candidate precision against gold | 73.7% |
| First generated candidate accepted | 71/80 |
| Generation p50 per call | 362.4ms |
| Generation p95 per call | 463.7ms |

The candidate set covered 98.75% of cases. The generator's first candidate was
already correct in 88.75%, but selecting from the generated options raised the
Qwen3 4B result to 96.25%.

The selector prompt lists `A`, `B`, `C`, and so on and requires one letter. The
program maps the letter back to candidate text. This was more stable for Qwen3
than asking it to reproduce long option text.

## 6. Candidate Source Ablation

All rows use Qwen3 4B as the selector and the same 80 polysemy cases.

| Candidate source | Gold available | Final accepted | Conditional | Selector p95 |
| --- | ---: | ---: | ---: | ---: |
| Dictionary only | 43/80 | 39/80 (48.8%) | 90.7% | 264.09ms |
| Generated only | 79/80 | 77/80 (96.3%) | 97.5% | 220.92ms |
| Generated, then dictionary | 79/80 | 77/80 (96.3%) | 97.5% | 313.36ms |
| Dictionary, then generated | 79/80 | 73/80 (91.3%) | 92.4% | 274.64ms |
| Compound prompt plus fallback | 79/80 | 75/80 (93.8%) | 94.9% | 250.08ms |

The dictionary selector performs well when a correct sense is present, but a
correct sense exists for only 43/80 cases. Adding generated candidates raises
coverage, but dictionary distractors reduce accuracy when placed first.
Generated-first plus dictionary ties generated-only on quality while increasing
latency.

Conclusion: for contextual disambiguation, the generated candidate set is both
better and simpler. The production dictionary should be bypassed rather than
merged.

## 7. Selector Models

Same generated candidate set:

| Selector | Final accepted | Conditional | p50 | p95 | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3 4B | 77/80 (96.3%) | 97.5% | 178.11ms | 220.92ms | about 2.7GB |
| Qwen3 0.6B | 71/80 (88.8%) | 89.9% | 42.83ms | 47.95ms | about 0.9GB |

Qwen3 0.6B is viable if candidate generation uses another model and the product
can keep both loaded. On its own, it does not generate the needed candidates
reliably enough. The simple and stable quality recommendation remains Qwen3 4B
for both stages.

Index-Translate 2B remains a separate raw-context option. Its earlier
dictionary-list tests were not strong enough to justify another candidate
selector matrix.

## 8. End-To-End Cost

Per-case totals are calculated from measured calls, not from a production
instrumentation run.

| Path | Accepted | p50 | p95 |
| --- | ---: | ---: | ---: |
| Qwen3 4B raw context, one call | 71.2% | 260.59ms | 283.38ms |
| Qwen3 4B compound generation, fallback, selection | 93.8% | 625.61ms | 701.86ms |
| Qwen3 4B two generations plus selection | 96.3% | 939.11ms | 1070.89ms |

The quality path is roughly 3.8 times the p95 of the one-call contextual
Qwen3 4B path, and 6.1 times its non-context p95. It is not suitable for every
keystroke and must remain tied to candidate dwell. The existing rule still
applies: no model request during rapid candidate churn.

## 9. Context Availability

The tool probe uses:

- `kAXFocusedUIElementAttribute`
- `kAXSelectedTextRangeAttribute`
- `kAXStringForRangeParameterizedAttribute`
- `AXTextInputMarkedRange` exclusion

| App | Focus role | Bounded range read | Before context | After context |
| --- | --- | --- | --- | --- |
| TextEdit | `AXTextArea` | supported | read | empty at end |
| Chrome | `AXTextArea` | supported | read | empty at end |
| Safari | `AXTextArea` | supported | read | empty at end |

There is no general macOS “current input content” API outside Accessibility
that works across third-party apps. `NSTextInputClient` is an in-process input
protocol, and TIS exposes input-source state rather than application text.
Accessibility is the appropriate mechanism for standard native controls.

Canvas editors and custom text engines may not support `AXStringForRange`.
They must degrade to target-only translation. Do not introduce OCR solely to
recover context for them.

## 10. Privacy And Safety Boundary

- Read only a bounded range around the caret, never the full text field.
- Keep the target explicit. Context disambiguates the target; it must not be
  used to infer a different target.
- Skip secure input, password fields, and mouse or keyboard selections.
- Do not persist context, candidates, or generated translations.
- Do not log context text.
- Use context only with a local model in the first implementation.
- Do not send context to OpenAI-compatible providers without a separate,
  explicit product decision and consent design.
- Hash context for in-memory cache keys. The current text-only cache key is
  insufficient because the same target may need different answers in different
  contexts.

## 11. Proposed Integration Plan

This plan is a follow-up proposal, not part of the current branch.

### Phase 1: held-out validation

- Add at least 200 synthetic cases not used to tune prompts or gold choices.
- Preserve paired polysemy cases and include sentence, business, control, and
  unavailable-context cases.
- Run the quality and balanced paths unchanged.
- Require at least a 10 percentage-point gain over target-only Qwen3 4B on the
  held-out ambiguity subset.
- Require no more than a 2 percentage-point regression on controls.

### Phase 2: isolated context transport

- Add a `CandidateContext` value containing bounded before/after text and a
  capability status.
- Extend `FocusMonitor` with one bounded range read after the existing focus and
  selection checks.
- Add a contextual translation protocol instead of changing every existing
  translation engine.
- Keep the existing target-only router unchanged for unsupported models and
  unavailable context.

### Phase 3: model-only candidate pipeline

- Enable it only when Qwen3 4B is the active model.
- Use `compound_aware` first. If fewer than two options return, run the fallback
  prompt once.
- Prefer the balanced path first. Offer the two-generation quality path only if
  product testing accepts a roughly one-second p95.
- Do not query the dictionary inside this path.
- Do not use OCR.

### Phase 4: lifecycle and UI

- Add a user-visible opt-in such as “高质量上下文翻译”.
- Explain that only nearby text around the caret is read locally.
- Add a context digest to `TranslationMemoKey`.
- Cancel all context-generation tasks when the candidate revision changes.
- Keep the current HUD open during candidate composition and update in place.
- Do not add a fixed delay after translation; dwell remains the only trigger.
- Respect an unavailable-context fallback without showing an error.

Suggested future types:

```swift
struct CandidateContext: Sendable, Equatable {
    let before: String
    let after: String
    let availability: Availability
}

protocol ContextualTranslationEngine: Sendable {
    func translate(
        _ candidate: Candidate,
        context: CandidateContext
    ) async throws -> TranslationResult?
}
```

## 12. Go/No-Go

| Question | Result |
| --- | --- |
| Does context add useful signal? | Yes, strongly for Qwen3 4B |
| Is raw contextual translation enough? | No, 71.2% |
| Is generated-candidate selection better? | Yes, 96.3% in this synthetic set |
| Does the dictionary help this path? | No |
| Is the cheapest model sufficient? | No for generation; 0.6B is a possible selector only |
| Is OCR required? | No for standard AX text controls |
| Is the latency compatible with automatic default mode? | No |
| Is it worth an opt-in prototype? | Yes |
| Is the result independent enough to ship immediately? | No, needs held-out validation |

Recommended decision: **continue with an opt-in Qwen3 4B prototype after
held-out validation; bypass the dictionary for context mode; keep the existing
dictionary fallback outside context mode.**

## 13. Artifacts

- Corpus: `Tools/ModelLab/eval/context_cases.json`
- Manual gold choices: `Tools/ModelLab/eval/context_choice_gold.json`
- Direct context results: `Tools/ModelLab/results/context-*.json`
- Generated candidates:
  `Tools/ModelLab/results/context-generated-candidates.json`
- Dictionary candidate bank:
  `Tools/ModelLab/results/context-candidate-bank.json`
- Candidate-source ablations:
  `Tools/ModelLab/results/context-ablation-*.json`
- AX probe: `Tools/GlintEval/Sources/ContextAXProbe/main.swift`
- Candidate tools: `Tools/CandidateLab/`

## 14. Sources

- DeepL context parameter:
  https://developers.deepl.com/api-reference/translate/request-translation
- DeepL context guide:
  https://developers.deepl.com/docs/learning-how-tos/examples-and-guides/how-to-use-context-parameter
- Google Cloud Translation glossaries:
  https://docs.cloud.google.com/translate/docs/advanced/glossary
- Hy-MT2:
  https://github.com/Tencent-Hunyuan/Hy-MT2
- Context-aware machine translation survey:
  https://arxiv.org/html/2506.07583v1
- CC-CEDICT:
  https://cc-cedict.org/
- ECDICT:
  https://github.com/skywind3000/ECDICT
- Wiktionary / Kaikki:
  https://kaikki.org/dictionary/Chinese/
