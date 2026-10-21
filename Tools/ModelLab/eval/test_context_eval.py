import unittest
from pathlib import Path

from run_context_eval import (
    ContextCase,
    build_prompt,
    clip_context,
    extract_target_output,
    load_cases,
    normalize_translation,
    score_output,
    system_prompt,
)


ROOT = Path(__file__).resolve().parent.parent


class ContextEvalTests(unittest.TestCase):
    def test_corpus_is_valid(self):
        cases = load_cases(ROOT / "eval" / "context_cases.json")

        self.assertEqual(len(cases), 120)
        self.assertEqual(len({case.id for case in cases}), 120)

    def test_clip_context_keeps_nearest_before_text(self):
        self.assertEqual(
            clip_context("一二三四五六", 3, from_end=True),
            "四五六",
        )
        self.assertEqual(
            clip_context("一二三四五六", 3, from_end=False),
            "一二三",
        )

    def test_prompt_includes_only_requested_context(self):
        case = ContextCase(
            id="case",
            kind="word",
            category="polysemy",
            target="方便",
            before="abcdefghijklmnopqrstuvwxyz",
            after="ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            references=("instant",),
            unacceptable=(),
            pair_id=None,
        )

        prompt = build_prompt(case, "m2")

        self.assertIn(
            "文本：cdefghijklmnopqrstuvwxyz【方便】ABCDEFGH",
            prompt,
        )
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz", prompt)

    def test_normalization_preserves_articles(self):
        self.assertEqual(
            normalize_translation("  The Result! "),
            "the result",
        )

    def test_scoring_accepts_reference_and_rejects_chinese(self):
        case = ContextCase(
            id="case",
            kind="word",
            category="polysemy",
            target="方便",
            before="",
            after="",
            references=("convenient",),
            unacceptable=("instant",),
            pair_id=None,
        )

        self.assertEqual(
            score_output("Convenient!", case),
            ("acceptable", ""),
        )
        self.assertEqual(
            score_output("方便", case),
            ("invalid", "chinese_output"),
        )

    def test_general_models_receive_system_instructions(self):
        self.assertIn(
            "Follow the user's output constraints",
            system_prompt(
                "mlx-community/Qwen3-0.6B-4bit"
            ),
        )
        self.assertIsNone(
            system_prompt(
                "zerodegress/Index-Translate-2B-MLX-4bit"
            )
        )

    def test_extracts_single_english_bracket_target(self):
        self.assertEqual(
            extract_target_output(
                "Please [process] these data first."
            ),
            ("process", "bracketed"),
        )
        self.assertEqual(
            extract_target_output("这是【处理】"),
            ("处理", "chinese_only"),
        )


if __name__ == "__main__":
    unittest.main()
