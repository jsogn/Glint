import json
import tempfile
import unittest
from pathlib import Path

from evaluate_override_ablation import (
    DEFAULT_CASES,
    load_cases,
    load_current_choices,
    load_overrides,
    prediction_status,
    summarize,
    visible_candidates,
)

ROOT = Path(__file__).resolve().parents[2]
OVERRIDES = ROOT / "Resources/Dictionary/overrides.json"


class OverrideAblationTests(unittest.TestCase):
    def test_stress_corpus_has_complete_pairs(self):
        overrides = load_overrides(OVERRIDES)
        cases = load_cases(DEFAULT_CASES, overrides)

        self.assertEqual(len(cases), 40)
        self.assertEqual(len({case.pair_id for case in cases}), 20)
        self.assertEqual(len({case.target for case in cases}), 20)
        self.assertTrue(all(case.target in overrides for case in cases))

    def test_static_override_cannot_cover_both_contexts(self):
        overrides = load_overrides(OVERRIDES)
        cases = load_cases(DEFAULT_CASES, overrides)
        pair = {
            case.role: case
            for case in cases
            if case.pair_id == "override-003"
        }

        aligned_status, _ = prediction_status(
            overrides["落地"][0],
            pair["aligned"],
        )
        conflict_status, reason = prediction_status(
            overrides["落地"][0],
            pair["conflict"],
        )

        self.assertEqual(aligned_status, "acceptable")
        self.assertEqual(conflict_status, "incorrect")
        self.assertEqual(reason, "listed_unacceptable")

    def test_summary_is_derived_from_case_statuses(self):
        overrides = load_overrides(OVERRIDES)
        cases = load_cases(DEFAULT_CASES, overrides)
        rows = []
        for case in cases:
            status, reason = prediction_status(
                overrides[case.target][0],
                case,
            )
            rows.append(
                {
                    "id": case.id,
                    "pair_id": case.pair_id,
                    "target": case.target,
                    "role": case.role,
                    "variant": "current_override",
                    "status": status,
                    "top3_status": status,
                    "reason": reason,
                    "latency_ms": 0.0,
                }
            )

        summary = summarize(cases, rows)["variants"]["current_override"]

        self.assertEqual(summary["acceptable"], 20)
        self.assertEqual(summary["aligned_acceptable"], 20)
        self.assertEqual(summary["conflict_acceptable"], 0)
        self.assertEqual(summary["paired_both_acceptable"], 0)

    def test_visible_candidates_follow_hud_limit(self):
        self.assertEqual(
            visible_candidates(["handle", "process", "deal with"]),
            ["handle", "process", "deal with"],
        )
        self.assertEqual(
            visible_candidates(["a" * 30, "b" * 20, "c"]),
            ["a" * 30],
        )

    def test_current_route_choices_cover_stress_targets(self):
        overrides = load_overrides(OVERRIDES)
        cases = load_cases(DEFAULT_CASES, overrides)
        choices = load_current_choices(
            ROOT
            / "Tools/DictionaryLab/results/current-route-choices.json",
            cases,
        )

        self.assertEqual(len(choices), 20)
        self.assertTrue(all(values for values in choices.values()))

    def test_loader_rejects_non_override_target(self):
        overrides = load_overrides(OVERRIDES)
        document = json.loads(DEFAULT_CASES.read_text(encoding="utf-8"))
        document["cases"][0]["target"] = "不存在的词"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cases.json"
            path.write_text(
                json.dumps(document, ensure_ascii=False),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "is not a runtime override",
            ):
                load_cases(path, overrides)


if __name__ == "__main__":
    unittest.main()
