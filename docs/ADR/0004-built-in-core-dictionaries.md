# ADR-0004: Core dictionaries are read-only app resources

## Status

Accepted on 2026-10-22.

## Decision

CC-CEDICT, ECDICT, and Wiktionary are distributed inside `Glint.app` and loaded
directly as read-only SQLite resources. They are not copied into Application
Support and do not expose install or uninstall actions.

Future optional dictionaries use the plugin manager and can be installed from a
catalog when a stable, license-compatible source is available.

## Consequences

- Core dictionaries work offline without an installation step.
- Each bundled dictionary occupies disk space once.
- Core dictionary updates ship with app updates.
- Users cannot reclaim the bundled dictionary bytes separately.
- Optional dictionaries retain download, update, and uninstall behavior.
