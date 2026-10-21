import unittest

from generate_context_candidates import (
    evaluate_candidates,
    parse_candidate_lines,
)
from merge_candidate_sources import merge, normalize


class CandidateGenerationTests(unittest.TestCase):
    def test_parse_candidate_lines_filters_noise(self):
        self.assertEqual(
            parse_candidate_lines(
                "1. instant\n- ready-to-eat\n解释\n方便\ninstant"
            ),
            ["instant", "ready-to-eat"],
        )

    def test_merge_preserves_dictionary_order_and_adds_generated(self):
        bank = {
            "source_counts": {},
            "coverage": {
                "case_count": 1,
                "eligible_two_plus": 1,
                "correct_reference_present": 0,
            },
            "entries": {
                "case": {
                    "target": "方便",
                    "choices": ["convenient"],
                }
            },
        }
        generated = {
            "model_id": "model",
            "entries": {
                "case": {
                    "target": "方便",
                    "candidates": ["instant", "Convenient"],
                    "references": ["instant"],
                }
            },
        }

        result = merge(
            bank,
            generated,
            12,
            {"case": ["instant", "ready-to-eat"]},
        )

        self.assertEqual(
            result["entries"]["case"]["choices"],
            ["convenient", "instant"],
        )
        self.assertEqual(
            result["coverage"]["generated_reference_present"],
            1,
        )
        self.assertEqual(
            result["coverage"]["gold_correct_option_available"],
            1,
        )
        self.assertEqual(
            result["coverage"]["gold_choice_precision"],
            0.5,
        )
        self.assertEqual(normalize("Ready-to-eat!"), "ready to eat")

    def test_merge_can_prefer_generated_candidates(self):
        bank = {
            "source_counts": {},
            "coverage": {"case_count": 1},
            "entries": {
                "case": {
                    "choices": ["convenient", "instant"],
                }
            },
        }
        generated = {
            "model_id": "model",
            "entries": {
                "case": {
                    "candidates": ["instant", "ready-to-eat"],
                    "references": ["instant"],
                }
            },
        }

        result = merge(
            bank,
            generated,
            2,
            preferred_source="generated",
        )

        self.assertEqual(
            result["entries"]["case"]["choices"],
            ["instant", "ready-to-eat"],
        )

    def test_candidate_evaluation_separates_recall_and_precision(self):
        entries = {
            "case": {
                "references": ["instant"],
                "candidates": ["instant", "convenient"],
                "generations": [
                    {
                        "prompt": "direct",
                        "candidates": ["instant", "convenient"],
                    },
                    {
                        "prompt": "compound_aware",
                        "candidates": [],
                    },
                ],
            }
        }

        result = evaluate_candidates(
            entries,
            {"case": ["instant", "ready-to-eat"]},
        )

        self.assertEqual(result["available"], 1)
        self.assertEqual(result["candidate_precision"], 0.5)
        self.assertEqual(result["top1_accuracy"], 1.0)


if __name__ == "__main__":
    unittest.main()
