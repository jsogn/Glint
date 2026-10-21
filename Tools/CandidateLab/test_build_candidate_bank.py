import unittest

from build_candidate_bank import (
    Candidate,
    add_candidate,
    clean_sense,
    normalize,
    reference_in_candidates,
    split_senses,
)


class CandidateBankTests(unittest.TestCase):
    def test_normalization_collapses_punctuation(self):
        self.assertEqual(
            normalize("  Take-a-taxi! "),
            "take a taxi",
        )

    def test_split_senses_removes_metadata(self):
        self.assertEqual(
            split_senses(
                "convenient; suitable; to facilitate; CL:個|个"
            ),
            ["convenient", "suitable", "to facilitate"],
        )
        self.assertIsNone(clean_sense("surname Xin"))

    def test_candidates_merge_sources(self):
        candidates = {}
        add_candidate(
            candidates,
            "convenient",
            "cedict",
            {"reading": "fang1 bian4"},
        )
        add_candidate(
            candidates,
            "Convenient",
            "wiktionary",
            {"part_of_speech": "adj"},
        )

        candidate = next(iter(candidates.values()))
        self.assertEqual(
            candidate.sources,
            {"cedict", "wiktionary"},
        )
        self.assertEqual(len(candidate.details), 2)

    def test_reference_coverage(self):
        candidates = [
            Candidate(
                text="take a taxi",
                sources={"cedict"},
            ),
            Candidate(
                text="play",
                sources={"cedict"},
            ),
        ]

        self.assertTrue(
            reference_in_candidates(
                ["Take a taxi!"],
                candidates,
            )
        )
        self.assertFalse(
            reference_in_candidates(["read"], candidates)
        )


if __name__ == "__main__":
    unittest.main()
