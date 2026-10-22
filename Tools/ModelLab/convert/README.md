# Model conversion

Place model conversion scripts here:

- Hugging Face → CTranslate2 for OPUS-MT / M2M100;
- Hugging Face → MLX for Qwen3-4B.

Generated model binaries are stored outside the repository and are not committed.

## OPUS-MT build asset

`Resources/Plugins/mt-opus-zh-en/model-lock.json` pins the upstream model
revision, converter dependencies, quantization, and output hashes.

Prepare or verify the ignored build cache from the repository root:

```bash
./scripts/prepare_opus_model.sh
```

The script uses `hf-mirror.com` by default. Override the endpoint with
`GLINT_HF_ENDPOINT` when needed. The generated CTranslate2 model remains in
`Resources/Plugins/mt-opus-zh-en/model`, which is ignored by Git, and is copied
into the final App bundle at build time.
