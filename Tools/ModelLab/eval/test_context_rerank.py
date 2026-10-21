import json
import tempfile
import unittest
from pathlib import Path

from run_context_eval import load_cases
from run_context_rerank import (
    build_choice_prompt,
    load_gold_choices,
    load_choice_map,
    normalize_choice,
    paired_polysemy_cases,
    reference_choices,
    resolve_choice,
    score_choice,
)


ROOT = Path(__file__).resolve().parent.parent


class ContextRerankTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cases = load_cases(ROOT / "eval" / "context_cases.json")
        cls.cases = paired_polysemy_cases(cases)

    def test_corpus_has_complete_polysemy_pairs(self):
        self.assertEqual(len(self.cases), 80)
        pair_ids = {case.pair_id for case in self.cases}
        self.assertEqual(len(pair_ids), 40)

    def test_prompt_contains_context_and_choices(self):
        case = next(
            case
            for case in self.cases
            if case.id == "amb-001-a"
        )
        prompt = build_choice_prompt(case, "r2")

        self.assertIn("这家店卖【方便】面", prompt)
        self.assertIn("A. instant", prompt)
        self.assertIn("B. convenient", prompt)
        self.assertIn("选项字母", prompt)

    def test_score_accepts_reference_and_rejects_wrong_option(self):
        case = next(
            case
            for case in self.cases
            if case.id == "amb-001-a"
        )

        self.assertEqual(
            score_choice("instant", case),
            ("acceptable", ""),
        )
        self.assertEqual(
            score_choice("convenient", case),
            ("incorrect", "wrong_option"),
        )
        self.assertEqual(
            score_choice("full sentence", case),
            ("incorrect", "not_an_option"),
        )

    def test_choice_letters_map_to_the_selected_option(self):
        case = next(
            case
            for case in self.cases
            if case.id == "amb-001-a"
        )

        self.assertEqual(resolve_choice("A", case), "instant")
        self.assertEqual(
            score_choice("A", case),
            ("acceptable", ""),
        )
        self.assertEqual(
            score_choice("B.", case),
            ("incorrect", "wrong_option"),
        )
        self.assertEqual(
            resolve_choice("B. convenient", case),
            "convenient",
        )

    def test_text_option_starting_with_a_is_not_treated_as_a_label(self):
        case = next(
            case
            for case in self.cases
            if case.id == "amb-011-a"
        )
        choices = ["other", "a bit"]

        self.assertEqual(
            resolve_choice("a bit", case, choices),
            "a bit",
        )

    def test_score_accepts_safe_choice_surface_variants(self):
        case = next(
            case
            for case in self.cases
            if case.id == "amb-002-a"
        )

        self.assertEqual(
            score_choice("- to process", case),
            ("acceptable", ""),
        )

    def test_normalize_choice_handles_qualifiers_and_punctuation(self):
        self.assertEqual(
            normalize_choice("- (of a plane) to Land!"),
            "land",
        )
        self.assertEqual(
            normalize_choice("1. ready-to-eat"),
            "ready to eat",
        )

    def test_choices_are_unique(self):
        case = self.cases[0]
        values = [value.lower() for value in reference_choices(case)]

        self.assertEqual(len(values), len(set(values)))

    def test_gold_choices_cover_every_reference(self):
        gold = load_gold_choices(
            ROOT / "eval" / "context_choice_gold.json"
        )

        self.assertEqual(set(gold), {case.id for case in self.cases})
        for case in self.cases:
            accepted = {normalize_choice(value) for value in gold[case.id]}
            for reference in case.references:
                self.assertIn(normalize_choice(reference), accepted)

    def test_load_choice_map_can_select_one_generation_prompt(self):
        payload = {
            "entries": {
                "case": {
                    "generations": [
                        {
                            "prompt": "direct",
                            "candidates": ["direct"],
                        },
                        {
                            "prompt": "compound_aware",
                            "candidates": ["compound"],
                        },
                        {
                            "prompt": "fallback",
                            "candidates": ["fallback-a", "fallback-b"],
                        },
                    ]
                }
            }
        }
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".json",
        ) as handle:
            json.dump(payload, handle)
            handle.flush()
            choices = load_choice_map(
                Path(handle.name),
                "compound_aware",
                "fallback",
            )

        self.assertEqual(
            choices,
            {"case": ["compound", "fallback-a", "fallback-b"]},
        )


if __name__ == "__main__":
    unittest.main()
