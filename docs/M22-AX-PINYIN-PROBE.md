# M22 AX Pinyin Capability Probe

- Date: 2026-10-22
- Scope: read-only Accessibility capability check
- Production behavior changed: no

## 1. Test

The probe read only the Apple Pinyin candidate-list subtree.

- App: TextEdit
- Input source: Pinyin - Simplified
- Typed sequence: `jieguo`
- Selected candidate: `结果`
- Candidate list identifier: `InputMethodCandidateList`

No text field content was read, captured, or saved.

## 2. Observed AX Surface

The candidate list exposed:

- `AXRole`: `AXList`
- `AXIdentifier`: `InputMethodCandidateList`
- `AXSelectedChildren`
- `AXVisibleChildren`
- `AXChildren`
- `AXFrame`, `AXPosition`, `AXSize`

Each selected/visible candidate exposed:

- `AXTitle`
- `AXDescription`
- `AXValueDescription`
- `AXRoleDescription`
- frame and parent/window references

For `结果`, all text-bearing attributes contained only the Chinese candidate
surface. `AXRoleDescription` was:

```text
结构的结，如果的果
```

That value explains the characters using Chinese words. It is not pinyin,
romanization, or pronunciation.

## 3. Decision

Do not implement pinyin-aware ranking from the public candidate AX surface.

There is no observed pinyin/reading field to distinguish cases such as:

- `结果`: jiéguǒ / jiēguǒ
- `地方`: dìfāng / dìfang
- `长短`: chángduǎn / zhǎngduǎn

The schema-v2 pinyin column remains useful for dictionary inventory and future
context/sense work, but it cannot currently be joined to the selected IME
candidate through Accessibility.

Stop this research direction. Re-test only if Apple adds a documented reading
attribute to `InputMethodCandidateList`.

## 4. Reproduce

```bash
swift build --package-path Tools/GlintEval --product CandidateAXProbe
Tools/GlintEval/.build/debug/CandidateAXProbe \
  --pid <TextEdit PID> \
  --seconds 30
```

The probe prints JSON only after a selected candidate is present.
