"""Shared candidate helpers for offline dictionary evaluation."""

from __future__ import annotations

from benchmark_lexicon import normalize_candidate


def merge_candidates(*groups: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for group in groups:
        for value in group:
            key = normalize_candidate(value)
            if key and key not in seen:
                seen.add(key)
                result.append(value)
    return result


def visible_candidates(
    candidates: list[str],
    max_characters: int = 48,
) -> list[str]:
    selected: list[str] = []
    length = 0
    for candidate in candidates[:3]:
        separator_length = 3 if selected else 0
        proposed_length = length + separator_length + len(candidate)
        if selected and proposed_length > max_characters:
            break
        selected.append(candidate)
        length = proposed_length
    return selected
