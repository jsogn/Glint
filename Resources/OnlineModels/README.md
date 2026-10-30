# Online Model Sources

Directories here are model packaging sources. They are not App resources and
must not be added to `project.yml`.

OPUS-MT:

- `mt-opus-zh-en/model` is generated locally and ignored by Git.
- `manifest.json` is embedded in the archive and intentionally leaves the
  archive checksum to the catalog.
- `../catalog.json` is the install authority and carries the final
  archive size and SHA256.
- Build the release archive with `scripts/package_opus_model_data.sh`.

The model archive must contain data files only. The CTranslate2,
SentencePiece, and bridge dynamic libraries are bundled from
`Resources/CTranslate2Runtime` and are never accepted from a downloaded model.
