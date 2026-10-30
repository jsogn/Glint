# CTranslate2Bridge

Objective-C++/C++ bridge for CTranslate2.

The bridge exposes a small C ABI consumed by `GlintInference` through
`dlopen`/`dlsym`:

- `glint_ct2_create(model_dir, &error)`
- `glint_ct2_translate(handle, text)`
- `glint_ct2_free_string(value)`
- `glint_ct2_destroy(handle)`

The implementation links the CTranslate2 dylib from the Python wheel and a
locally built SentencePiece shared library. It was validated with:

```text
今天天气不错 -> It's a nice day.
```

## Reproducible build

Run:

```bash
./scripts/build_ctranslate2_runtime.sh
```

The script pins CTranslate2 4.8.3 and SentencePiece 0.2.2 by commit, builds
SentencePiece and the bridge for arm64 with a macOS 15 deployment target, signs
the generated libraries, verifies their architectures and minimum system
versions, and updates the binary hashes in `runtime-lock.json`.

Source checkouts are cached under `Tools/ModelLab/.cache/ctranslate2-runtime`
and are not committed. Override that location with `GLINT_CT2_BUILD_CACHE`.

The bridge and CTranslate2/SentencePiece dylibs are bundled at
`Resources/CTranslate2Runtime/bin`. The converted OPUS-MT model is prepared by
`scripts/prepare_opus_model.sh` under `Resources/OnlineModels/mt-opus-zh-en`
and published as a separate data archive by
`scripts/package_opus_model_data.sh`.

Rules:

- No UI or AppKit code here.
- No model download code here.
- Keep the C++ surface small and testable.
