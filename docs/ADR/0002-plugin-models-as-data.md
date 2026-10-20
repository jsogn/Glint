# ADR-0002: Plugin models are data

## Status

Accepted.

## Decision

Dictionary and translation plugins are manifested data bundles. The app ships
fixed runtime adapters for SQLite, CTranslate2, MLX, and optionally Apple
Translation. Plugins cannot contain dylibs, scripts, or executable code.

## Consequences

- Download/install can verify size and SHA256.
- A plugin cannot execute arbitrary code inside Glint.
- Adding a new runtime requires an app update, not a plugin update.
- Model licensing and manifest metadata remain explicit.
