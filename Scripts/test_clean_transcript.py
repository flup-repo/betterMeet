import tempfile
from pathlib import Path
import unittest

from clean_transcript import clean, publish, validate_response


class CleanupTests(unittest.TestCase):
    def test_punctuation_only(self):
        original = [{"id": 0, "text": "hello world"}]
        edited = {"segments": [{"id": 0, "text": "Hello, world."}]}
        self.assertEqual(validate_response(original, edited), edited["segments"])

    def test_rejects_changes(self):
        original = [{"id": 0, "text": "price is 649"}]
        for items in [
            [{"id": 0, "text": "price is 694"}],
            [{"id": 0, "text": "price is"}],
            [{"id": 1, "text": "price is 649"}],
            [{"id": 0, "text": "price is 649 **"}],
            [],
        ]:
            with self.assertRaises(ValueError):
                validate_response(original, {"segments": items})

    def test_exclusive_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "transcript.cleaned.md"
            publish(output, "first")
            with self.assertRaises(FileExistsError):
                publish(output, "second")
            self.assertEqual(output.read_text(), "first")

    def test_invalid_timeout_and_cloud_model_do_not_write(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            for timeout in [0, -1, float("nan"), float("inf")]:
                with self.assertRaises(ValueError):
                    clean(directory, "local-model", timeout)
            with self.assertRaises(ValueError):
                clean(directory, "model:cloud", 10)
            self.assertEqual(list(directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
