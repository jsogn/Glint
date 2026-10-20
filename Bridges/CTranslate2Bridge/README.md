# CTranslate2Bridge

Objective-C++/C++ bridge for CTranslate2.

The bridge exposes a small C ABI consumed by `GlintInference` through
`dlopen`/`dlsym`:

- `glint_ct2_create(model_dir, &error)`
- `glint_ct2_translate(handle, text)`
- `glint_ct2_free_string(value)`
- `glint_ct2_destroy(handle)`

The current implementation links the CTranslate2 dylib from the Python wheel
and a locally built SentencePiece shared library. It was validated with:

```text
今天天气不错 -> It's a nice day.
```

Build inputs:

- `Vendor/CTranslate2` (headers)
- `Vendor/sentencepiece-shared-install`
- `Vendor/ct2/libctranslate2.dylib`
- `Vendor/ct2/libsentencepiece.0.dylib`

The bridge is loaded from `Resources/CT2/libglintct2.dylib` in the dev bundle.
The model and dylibs are local development assets; production moves them to a
downloaded plugin directory.

Rules:

- No UI or AppKit code here.
- No model download code here.
- Keep the C++ surface small and testable.
