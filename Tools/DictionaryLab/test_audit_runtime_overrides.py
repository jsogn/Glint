import json
import unittest
from pathlib import Path

from audit_runtime_overrides import classify


ROOT = Path(__file__).resolve().parents[2]
OVERRIDES = ROOT / "Resources/Dictionary/overrides.json"
LEXICON = ROOT / "build/dictionary-core/normalized_lexicon.sqlite3"
CLASSIFICATION = (
    ROOT / "Tools/DictionaryLab/results/override-classification.json"
)


class RuntimeOverrideAuditTests(unittest.TestCase):
    @unittest.skipUnless(
        LEXICON.is_file(),
        "normalized research lexicon is not built",
    )
    def test_every_override_has_one_decision(self):
        result = classify(OVERRIDES, LEXICON)

        self.assertEqual(result["summary"]["override_count"], 105)
        self.assertEqual(result["summary"]["retire_runtime"], 44)
        self.assertEqual(result["summary"]["fallback_only"], 61)
        self.assertEqual(
            result["summary"]["retire_runtime"]
            + result["summary"]["fallback_only"],
            105,
        )
        self.assertEqual(result["missing_retire_terms"], [])
        self.assertEqual(
            {entry["test_role"] for entry in result["entries"]},
            {"fixture_only"},
        )

    @unittest.skipUnless(
        LEXICON.is_file(),
        "normalized research lexicon is not built",
    )
    def test_current_policy_keeps_only_invalid_fragment(self):
        result = classify(OVERRIDES, LEXICON)
        actions = {
            entry["term"]: entry["action"]
            for entry in result["blocked_terms"]
        }

        self.assertEqual(
            actions,
            {"你号": "keep_exact_invalid_fragment"},
        )

    def test_runtime_data_contains_only_fallback_entries(self):
        classification = json.loads(
            CLASSIFICATION.read_text(encoding="utf-8")
        )
        expected = {
            entry["term"]
            for entry in classification["entries"]
            if entry["action"] == "fallback_only"
        }
        retired = {
            entry["term"]
            for entry in classification["entries"]
            if entry["action"] == "retire_runtime"
        }
        runtime = json.loads(OVERRIDES.read_text(encoding="utf-8"))

        self.assertEqual(set(runtime["overrides"]), expected)
        self.assertEqual(set(runtime["retiredOverrides"]), retired)
        self.assertNotIn("blocked", runtime)


if __name__ == "__main__":
    unittest.main()
