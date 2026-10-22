import gzip
import sqlite3
import tempfile
import unittest
from pathlib import Path

from build_sqlite import build, parse_entry


class DictionaryBuilderTests(unittest.TestCase):
    def test_parser_preserves_readings_and_senses(self):
        entry = parse_entry(
            "看 看 [kan4] /to see; to look at/to read/"
        )

        self.assertEqual(entry[0], "看")
        self.assertEqual(entry[1], "看")
        self.assertEqual(entry[2], "kan4")
        self.assertEqual(entry[3], ("to see; to look at", "to read"))

    def test_build_keeps_duplicate_headwords(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            archive = directory_path / "cedict.gz"
            output = directory_path / "cedict.sqlite3"
            with gzip.open(archive, "wt", encoding="utf-8") as handle:
                handle.write("打 打 [da2] /dozen/\n")
                handle.write("打 打 [da3] /to hit/\n")

            entries, senses = build(archive, output)
            connection = sqlite3.connect(output)
            try:
                rows = connection.execute(
                    """
                    SELECT pinyin, gloss
                    FROM entries
                    WHERE simplified = '打'
                    ORDER BY line_order, sense_order
                    """
                ).fetchall()
                version = connection.execute(
                    "PRAGMA user_version"
                ).fetchone()[0]
            finally:
                connection.close()

        self.assertEqual(entries, 2)
        self.assertEqual(senses, 2)
        self.assertEqual(version, 2)
        self.assertEqual(rows, [("da2", "dozen"), ("da3", "to hit")])


if __name__ == "__main__":
    unittest.main()
