# M16 Context Disambiguation Evaluation

- Date: 2026-10-21
- Branch: `codex/evaluate-context-disambiguation`
- Models: Hy-MT2 1.8B, Qwen3 0.6B / 1.7B / 4B,
  Index-Translate 2B
- Corpus: 120 synthetic cases
- Decision: **default off; context is feasible only as a model-selective,
  opt-in capability**

## 1. Conclusion

Context contains useful disambiguation signal, but the current production
assets cannot convert that signal into a reliable target translation.

- Hy-MT2 cannot consistently follow an instruction to translate only the marked
  target. In the raw context run, `m1`–`m3` produced fewer acceptable results
  than the target-only baseline and frequently returned Chinese text or the full
  English sentence.
- The limitation is not exclusive to Hy-MT2. Qwen3 0.6B and 1.7B also fail to
  isolate the target reliably. Qwen3 4B and Index-Translate 2B preserve the
  format and show large context gains, but with substantially higher latency.
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

The current context feature does not pass the original universal latency gate
for automatic enablement. The model comparison below shows a viable selective
path for Qwen3 4B and Index-Translate 2B, but not for every installed model.

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

## 6. Cross-Model Comparison

All rows below use the 80 polysemy cases. Raw context means the model receives
the marked sentence and must emit only the target. Reranking means the correct
target sense is present in the supplied option set.

### Raw Context

| Model | No context | 24 + 8 context | Invalid | p95 no context | p95 context |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hy-MT2 1.8B | 21.3% | 12.5% | 65/80 | 50.0ms | 119.1ms |
| Qwen3 0.6B | 7.5% | 6.3% | 60/80 | 40.0ms | 49.4ms |
| Qwen3 1.7B | 20.0% | 1.3% | 78/80 | 80.2ms | 111.8ms |
| Qwen3 4B | 20.0% | 52.5% | 0/80 | 176.6ms | 283.4ms |
| Index-Translate 2B | 23.8% | 48.8% | 1/80 | 51.0ms | 129.7ms |

Qwen3 4B and Index-Translate 2B are the only local models that materially
benefit from raw context while preserving a usable output format. The cost is a
large p95 increase: about 107ms for Qwen3 4B and 79ms for Index-Translate 2B.

Hy-MT2, Qwen3 0.6B, and Qwen3 1.7B frequently return Chinese text, the full
sentence, or invalid formatting, so they must not receive raw contextual input.
OPUS-MT is a sequence-to-sequence translator with no instruction channel; a
smoke test translated the whole concatenated context rather than the target.
It is not suitable for this path.

### Oracle Context Reranking

| Model | No context | With context | Paired W/L/T | p95 no context | p95 context |
| --- | ---: | ---: | ---: | ---: | ---: |
| Hy-MT2 1.8B | 61.3% | 90.0% | 20/1/19 | 91.6ms | 93.9ms |
| Qwen3 0.6B | 77.5% | 92.5% | 12/0/28 | 34.6ms | 34.6ms |
| Qwen3 1.7B | 73.8% | 91.3% | 15/2/23 | 78.4ms | 79.1ms |
| Qwen3 4B | 68.8% | 98.8% | 23/0/17 | 166.6ms | 171.1ms |
| Index-Translate 2B | 65.0% | 95.0% | 23/0/17 | 80.4ms | 80.9ms |

When the candidate sense exists, context selection is highly effective across
all models and adds almost no latency. Qwen3 4B is the quality leader;
Index-Translate 2B is the best speed/quality balance; Qwen3 0.6B is the fastest
useful selector.

### Real Dictionary Candidate Reranking

The candidate bottleneck remains independent of the model:

| Model | No context | Context | Paired W/L/T |
| --- | ---: | ---: | ---: |
| Hy-MT2 1.8B | 12.1% | 15.2% | 2/0/31 |
| Qwen3 0.6B | 13.6% | 13.6% | 2/2/29 |
| Qwen3 4B | 15.2% | 24.2% | 5/0/28 |
| Index-Translate 2B | 15.2% | 22.7% | 5/0/28 |

- These rates use the 66 cases with at least two real dictionary choices.
- Only 19/80 ambiguous cases contain a correct dictionary sense.
- Better context selection cannot recover a sense that is absent from the
  candidate set.

## 7. Industry Patterns

Published products and documentation converge on separating source text from
context:

- DeepL exposes `context` as a separate request field. The context influences
  translation and is explicitly not translated itself.
- Google Cloud Translation recommends glossaries to force domain-specific
  interpretations of ambiguous words such as "bat".
- Hy-MT2's official prompt examples include a `【背景信息】` plus
  `【待翻译文本】` form and a multi-language translation-instruction profile.
  It has no default system prompt. Our test of the 1.8B model with that form
  still failed to reliably isolate the target, so prompt support alone does not
  guarantee target-only output.
- Context-aware LLM translation research uses prompting or fine-tuning with
  source and context represented separately. The survey notes that naive
  concatenation gives source and context the same priority, which can be
  suboptimal.

This supports a two-stage or model-specific design rather than one universal
translation prompt.

## 8. AX Feasibility

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

## 9. Gate Review

| Gate | Result |
| --- | --- |
| Ambiguous accuracy +10pp | Passed by Qwen3 4B and Index raw context; failed by Hy-MT2, Qwen3 0.6B, and 1.7B |
| Overall accuracy +3pp | Not established outside the polysemy subset |
| No control regression >2pp | Not established for the additional model matrix |
| Invalid/error unchanged | Passed by Qwen3 4B and Index raw context |
| p95 latency +20ms or less | Failed by every raw-context model; passed by oracle reranking |
| 24-character window retains 80% gain | Passed by Qwen3 4B and Index; 24 and 48 characters tied |
| TextEdit, Chrome, and Safari AX support | Passed |

## 10. Decision

Do not enable context globally in the current production model-first path.

Do not change the privacy policy, monitoring controller, cache key, or routing
behavior for this feature.

The supported model set has two viable selective paths:

1. **Qwen3 4B, highest quality:** enable context only as an explicit
   high-quality option. It gains 32.5 percentage points on raw polysemy
   translation and reaches 98.8% when choosing from known senses. Its p95
   increases by about 107ms and memory use is high.
2. **Index-Translate 2B, balanced:** enable context only as an explicit
   balanced option. It gains about 25 percentage points on raw polysemy
   translation and reaches 95% when choosing from known senses. Its p95
   increases by about 79ms.

Context must stay disabled for Hy-MT2 1.8B, Qwen3 0.6B, Qwen3 1.7B, and OPUS-MT.

Suggested capability matrix:

| Model | Raw context output | Context sense selection | Product rule |
| --- | --- | --- | --- |
| Qwen3 4B | Good | Best | Allow only as explicit high-quality context mode |
| Index-Translate 2B | Good | Strong | Allow only as explicit balanced context mode |
| Qwen3 0.6B | Poor | Strong and fastest | Use only in a future candidate-reranking stage |
| Qwen3 1.7B | Poor | Good | No raw context; reranking only |
| Hy-MT2 1.8B | Poor | Good | Keep default context-free |
| OPUS-MT | Not instruction-capable | Not evaluated | Keep context-free |

The next prerequisite is a better sense inventory or candidate-generation stage.
The current dictionary lacks a correct sense for most ambiguous cases. A
model-generated candidate set followed by Qwen3 0.6B or Qwen3 4B context
reranking is a more promising next experiment than changing AX extraction.

## 11. Sources

- DeepL context parameter:
  https://developers.deepl.com/api-reference/translate/request-translation
- DeepL context examples:
  https://developers.deepl.com/docs/learning-how-tos/examples-and-guides/how-to-use-context-parameter
- Google Cloud Translation glossaries:
  https://docs.cloud.google.com/translate/docs/advanced/glossary
- Hy-MT2 official model repository:
  https://github.com/Tencent-Hunyuan/Hy-MT2
- Survey on context-aware machine translation:
  https://arxiv.org/html/2506.07583v1
