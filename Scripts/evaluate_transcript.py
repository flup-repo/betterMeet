#!/usr/bin/env python3
"""Score one whole speaker track against a manually verified UTF-8 reference."""

import argparse
import json
from pathlib import Path
import re


def tokens(text):
    # Ignore punctuation/case, but never equate different numbers or spellings.
    return re.findall(r"\w+", text.casefold())


def error_counts(reference, hypothesis):
    # Each cell stores (edit distance, substitutions, deletions, insertions).
    # Two rows keep memory bounded for long meetings.
    previous = [(i, 0, 0, i) for i in range(len(hypothesis) + 1)]
    for i, word in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, candidate in enumerate(hypothesis, 1):
            if word == candidate:
                current.append(previous[j - 1])
                continue
            distance, substitutions, deletions, insertions = previous[j - 1]
            substitution = (distance + 1, substitutions + 1, deletions, insertions)
            distance, substitutions, deletions, insertions = previous[j]
            deletion = (distance + 1, substitutions, deletions + 1, insertions)
            distance, substitutions, deletions, insertions = current[j - 1]
            insertion = (distance + 1, substitutions, deletions, insertions + 1)
            current.append(min((substitution, deletion, insertion), key=lambda item: item[0]))
        previous = current
    distance, substitutions, deletions, insertions = previous[-1]
    return {
        "reference_words": len(reference),
        "hypothesis_words": len(hypothesis),
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "word_error_rate": distance / len(reference) if reference else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--transcript", type=Path, required=True)
    parser.add_argument("--speaker", choices=["me", "them"], required=True)
    args = parser.parse_args()
    doc = json.loads(args.transcript.read_text(encoding="utf-8"))
    hypothesis = " ".join(s["text"] for s in doc["segments"] if s["speaker"] == args.speaker)
    reference = args.reference.read_text(encoding="utf-8")
    if not tokens(reference):
        parser.error("reference must contain manually verified speech")
    score = error_counts(tokens(reference), tokens(hypothesis))
    score["status"] = doc.get("status", "unknown")
    score["model"] = doc.get("model")
    print(json.dumps(score, indent=2))


if __name__ == "__main__":
    main()
