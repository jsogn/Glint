import tempfile
import unittest
from pathlib import Path

from build_normalized_lexicon import parse_cedict_line


class NormalizedLexiconBuildTests(unittest.TestCase):
    def test_parses_all_cedict_senses(self):
        entry = parse_cedict_line(
            "打 打 [da3] /to hit; to strike/to fight/to play/"
        )

        self.assertIsNotNone(entry)
        self.assertEqual(entry.traditional, "打")
        self.assertEqual(entry.simplified, "打")
        self.assertEqual(entry.pinyin, "da3")
        self.assertEqual(
            entry.definitions,
            ("to hit; to strike", "to fight", "to play"),
        )

    def test_parser_preserves_distinct_readings(self):
        first = parse_cedict_line(
            "方便 方便 [fang1 bian4] /convenient/"
        )
        second = parse_cedict_line(
            "打 打 [da2] /dozen/"
        )

        self.assertEqual(first.pinyin, "fang1 bian4")
        self.assertEqual(second.pinyin, "da2")


if __name__ == "__main__":
    unittest.main()
