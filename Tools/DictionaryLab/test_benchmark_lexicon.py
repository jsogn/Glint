import unittest

from benchmark_lexicon import (
    evaluate,
    normalize_candidate,
    normalized_candidates,
    split_definition_candidates,
)
import sqlite3


class DictionaryBenchmarkTests(unittest.TestCase):
    def test_candidate_normalization(self):
        self.assertEqual(normalize_candidate("(fig.) To read;"), "read")
        self.assertEqual(normalize_candidate("the world"), "world")

    def test_definition_split_keeps_phrases(self):
        self.assertEqual(
            split_definition_candidates(
                "to look at; to watch/to read"
            ),
            ["to look at", "to watch", "to read"],
        )

    def test_evaluation_uses_expected_references(self):
        result = evaluate(
            [
                {
                    "id": "case",
                    "target": "看",
                    "category": "test",
                    "references": ["read"],
                }
            ],
            lambda _: ["to look at", "to read"],
        )

        self.assertTrue(result["overall"]["coverage"])
        self.assertFalse(result["overall"]["top1"])
        self.assertTrue(result["overall"]["top3"])
        self.assertEqual(result["overall"]["reference_recall"], 1.0)

    def test_ranked_candidates_prefer_ecdicted_frequency(self):
        connection = sqlite3.connect(":memory:")
        connection.executescript(
            """
            CREATE TABLE lexicon_entries(
                sense_id INTEGER PRIMARY KEY,
                headword TEXT,
                traditional TEXT,
                definition TEXT,
                source TEXT,
                source_priority INTEGER,
                source_order INTEGER,
                sense_order INTEGER,
                frequency INTEGER
            );
            CREATE TABLE rankings(
                term TEXT,
                english TEXT,
                frequency INTEGER,
                collins INTEGER,
                oxford INTEGER
            );
            INSERT INTO lexicon_entries VALUES(
                1, '工作', '工作', 'work', 'cedict', 30, 1, 0, NULL
            );
            INSERT INTO lexicon_entries VALUES(
                2, '工作', '工作', 'job', 'cedict', 30, 1, 1, NULL
            );
            INSERT INTO rankings VALUES(
                '工作', 'job', 100, 0, 0
            );
            INSERT INTO rankings VALUES(
                '工作', 'work', 1000, 0, 0
            );
            """
        )

        candidates = normalized_candidates(
            connection,
            "工作",
            None,
            rank=True,
        )

        self.assertEqual(candidates[:2], ["job", "work"])


if __name__ == "__main__":
    unittest.main()
