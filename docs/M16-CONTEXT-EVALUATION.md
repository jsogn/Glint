# M16 Context Disambiguation Evaluation

- Date: 2026-10-21
- Branch: `codex/evaluate-context-disambiguation`
- Model: `mlx-community/Hy-MT2-1.8B-4bit`
- Corpus: 120 synthetic cases
- Decision: **no-go for production integration with the current model and
  dictionary assets**

## 1. Conclusion

Context contains useful disambiguation signal, but the current production
assets cannot convert that signal into a reliable target translation.

- Hy-MT2 cannot consistently follow an instruction to translate only the marked
  target. In the raw context run, `m1`–`m3` produced fewer acceptable results
  than the target-only baseline and frequently returned Chinese text or the full
  English sentence.
- When context was used only to choose from a known set of correct senses,
  Hy-MT2 improved polysemy accuracy from 61.3% to 90.0%. This proves that
  context can help the model make the intended semantic decision.
- Real dictionary candidates are not good enough as that option set. Only
  66/80 ambiguous cases had at least two dictionary choices, and only 19/80
  cases had a correct sense in the dictionary choices.
- With real dictionary choices, acceptable results improved from 12.1% to only
  15.2%. The bottleneck is candidate coverage and quality, not the model's
  ability to use context.
- Accessibility bounded context extraction works in TextEdit, Chrome, and
  Safari. OCR is unnecessary for these controls.

The current context feature does not pass the agreed production gates.

## 2. Corpus

`Tools/ModelLab/eval/context_cases.json` contains 120 synthetic cases:

| Category | Cases | Description |
| --- | ---: | --- |
| Polysemy | 80 | 40 targets, each used in two contexts |
| Business | 15 | Technical and workplace terminology |
| Sentence | 15 | Context-sensitive short responses |
| Control | 10 | No-context ordinary words and sentences |

All paired cases use the same target in different contexts. No real user text is
used.

## 3. Raw Context Translation

Variants:

- `m0`: target only.
- `m1`: target plus 24 preceding characters.
- `m2`: target plus 24 preceding and 8 following characters.
- `m3`: target plus 48 preceding and 8 following characters.

| Variant | Acceptable | Rate | Invalid | p50 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| m0 | 40/120 | 33.3% | 0 | 44.87ms | 71.84ms |
| m1 | 14/120 | 11.7% | 92 | 86.34ms | 136.22ms |
| m2 | 19/120 | 15.8% | 88 | 96.94ms | 135.72ms |
| m3 | 19/120 | 15.8% | 88 | 97.33ms | 130.67ms |

`m1`–`m3` fail every quality and latency gate. The dominant failure mode is
instruction adherence: the specialized translation model translates the full
sentence or leaves the Chinese target in place.

Raw results:

- `Tools/ModelLab/results/context-hy-mt2.json`
- `Tools/ModelLab/results/context-hy-mt2-direct.json`

The `direct` result is the initial prompt version. The primary result includes
bounded extraction of one bracketed English target when the model provides it.
Neither version passes.

## 4. Oracle Sense Reranking

This run provides the model with a known set containing acceptable and
unacceptable senses. It measures the upper bound of context-based selection,
not whether production has suitable candidates.

| Variant | Acceptable | Rate | p50 | p95 |
| --- | ---: | ---: | ---: | ---: |
| r0: target plus choices | 49/80 | 61.3% | 62.12ms | 91.57ms |
| r2: target, context, choices | 72/80 | 90.0% | 77.80ms | 93.90ms |

Paired result: 20 wins, 1 loss, 19 ties. The oracle run demonstrates a 28.7
percentage-point gain with a 2.3ms p95 increase.

Raw result:

- `Tools/ModelLab/results/context-rerank-hy-mt2.json`

This result validates context as a signal but is not sufficient for production:
the correct option must already exist.

## 5. Real Dictionary Candidates

The production dictionary router was run over the same corpus:

- 70/120 total targets had at least two choices.
- 66/80 ambiguous targets had at least two choices.
- Only 19/80 ambiguous targets included an acceptable sense.

Ambiguous-case reranking with real dictionary choices:

| Variant | Acceptable | Rate | p50 | p95 |
| --- | ---: | ---: | ---: | ---: |
| r0: target plus choices | 8/66 | 12.1% | 71.98ms | 143.80ms |
| r2: target, context, choices | 10/66 | 15.2% | 79.24ms | 98.53ms |

Paired result: 2 wins, 0 losses, 31 ties. The improvement is not meaningful
because most cases cannot be answered by the available options.

The dictionary also exposed incorrect or irrelevant senses for several common
single-character targets, including surname readings and incomplete glosses.

Raw results:

- `Tools/ModelLab/results/context-choices.json`
- `Tools/ModelLab/results/context-rerank-hy-mt2-dictionary.json`

## 6. AX Feasibility

The tool-only probe uses `AXStringForRange` for a bounded window and does not
read the full field value.

| App | Role | Range | `AXStringForRange` | Before context | After context |
| --- | --- | --- | --- | --- | --- |
| TextEdit | `AXTextArea` | caret 26 | supported | read | empty at end |
| Chrome | `AXTextArea` | caret 26 | supported | read | empty at end |
| Safari | `AXTextArea` | caret 26 | supported | read | empty at end |

The probe received:

```text
固定合成测试文本【方便】我们在上下文探针中使用。
```

No screen recording or OCR was used. The AX approach is viable for these
representative controls, but canvas editors and custom text engines still
require a separate compatibility matrix.

Probe:

- `Tools/GlintEval/Sources/ContextAXProbe/main.swift`

## 7. Gate Review

| Gate | Result |
| --- | --- |
| Ambiguous accuracy +10pp | Failed for raw context and real dictionary rerank |
| Overall accuracy +3pp | Failed |
| No control regression >2pp | Raw context failed; control wording unchanged |
| Invalid/error unchanged | Failed |
| p95 latency +20ms or less | Raw context failed; oracle rerank passed |
| 24-character window retains 80% gain | No gain to retain in raw run |
| TextEdit and Chrome AX support | Passed |

## 8. Decision

Do not integrate context into the current production model-first path.

Do not change the privacy policy, monitoring controller, cache key, or routing
behavior for this feature.

Context should be reconsidered only if one of these prerequisites is met:

1. The translation model can reliably produce a target-only constrained output.
2. A stronger sense inventory is available, with reliable coverage for
   ambiguous single characters and business terminology.
3. A constrained decoding or two-stage design can select/generate a target
   translation without translating the full sentence.

The most promising next experiment is not more context extraction. It is
improving the sense inventory or using an instruction-following model with
target-only constrained output. The current AX path is available when that
prerequisite is ready.
