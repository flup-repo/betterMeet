import unittest

from evaluate_transcript import error_counts, tokens


class EvaluationTests(unittest.TestCase):
    def test_errors_are_counted_separately(self):
        score = error_counts(["a", "b", "c"], ["a", "x", "c", "d"])
        self.assertEqual(score["substitutions"], 1)
        self.assertEqual(score["insertions"], 1)
        self.assertEqual(score["deletions"], 0)
        self.assertAlmostEqual(score["word_error_rate"], 2 / 3)
        self.assertEqual(error_counts(["a", "b"], ["a"])["deletions"], 1)

    def test_normalization_keeps_numbers_and_languages(self):
        self.assertEqual(tokens("Hello, ROMÂNĂ 649!"), ["hello", "română", "649"])
        self.assertEqual(error_counts(tokens("649"), tokens("694"))["substitutions"], 1)


if __name__ == "__main__":
    unittest.main()
