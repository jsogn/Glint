import unittest
from pathlib import Path

from run_context_eval import load_cases
from run_context_rerank import (
    build_choice_prompt,
    paired_polysemy_cases,
    reference_choices,
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
        self.assertIn("- convenient", prompt)
        self.assertIn("- instant", prompt)

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

    def test_choices_are_unique(self):
        case = self.cases[0]
        values = [value.lower() for value in reference_choices(case)]

        self.assertEqual(len(values), len(set(values)))


if __name__ == "__main__":
    unittest.main()
