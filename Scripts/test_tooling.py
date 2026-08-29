#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The harness modules are imported here and by the scripts this suite spawns;
# leaving __pycache__ directories behind would dirty the working tree.
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Evals"))
sys.path.insert(0, str(ROOT / "Training"))

import editplan  # noqa: E402
import prepare_corpus  # noqa: E402

GOLD = ROOT / "Evals/fixtures/gold.jsonl"
ADVERSARIAL = ROOT / "Evals/fixtures/adversarial.jsonl"
CORPUS = ROOT / "Training/data/corpus.jsonl"
CLEANUP_PROMPT = ROOT / "Packages/Cleanup/Sources/Cleanup/CleanupPrompt.swift"

# Deliberately wrong predictions, one per dimension, so a collapsed or copied
# score cannot pass this suite.
WRONG_PREDICTIONS = {
    # Drops the verbatim vocabulary term while keeping every content word.
    "gold-004": {
        "output": "Keep Playground labs exactly as spoken.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "Keep", "c": "capitalization"},
                {"s": 2, "e": 3, "r": "labs", "c": "capitalization"},
                {"s": 6, "e": 6, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Capitalizes mid-sentence, so it no longer fits the Target Context.
    "gold-006": {
        "output": "And then we ship it.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "And", "c": "capitalization"},
                {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Mutates a number, so meaning is not preserved.
    "gold-008": {
        "output": "We shipped 104,729 records today.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "We", "c": "capitalization"},
                {"s": 2, "e": 3, "r": "104,729", "c": "correction"},
                {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Correct text, but the plan carries an unknown key, so it must fail closed.
    "gold-012": {
        "editPlan": {
            "v": 1,
            "e": [{"s": 0, "e": 1, "r": "Looks", "c": "capitalization", "x": 1}],
        }
    },
}
UNSAFE_ADVERSARIAL = "adv-style"


def load(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def predictions_for(gold, adversarial):
    records = []
    for fixture in gold:
        prediction = {
            "id": fixture["id"],
            "output": fixture["expected"],
            "editPlan": fixture["editPlan"],
            "outcome": "cleaned",
            "elapsedMilliseconds": 812.5,
        }
        prediction.update(WRONG_PREDICTIONS.get(fixture["id"], {}))
        records.append(prediction)
    for fixture in adversarial:
        records.append(
            {
                "id": fixture["id"],
                "output": fixture["raw"],
                "outcome": "cleaned" if fixture["id"] == UNSAFE_ADVERSARIAL else "fallback",
                "elapsedMilliseconds": 640.0,
            }
        )
    return records


def build_corpus():
    subprocess.run(
        ["python3", "Training/prepare_corpus.py"], cwd=ROOT, check=True, capture_output=True
    )


def evaluate(arguments, expect_success=True):
    result = subprocess.run(
        ["python3", "Evals/run.py", *arguments], cwd=ROOT, capture_output=True, text=True
    )
    if expect_success and result.returncode != 0:
        raise AssertionError(f"Evals/run.py failed: {result.stderr}")
    return result


class ToolingTests(unittest.TestCase):
    def test_fixture_integrity_is_deterministic_and_not_a_quality_claim(self):
        first = evaluate([]).stdout
        second = evaluate([]).stdout
        self.assertEqual(first, second)
        report = json.loads(first)
        self.assertEqual(report["mode"], "fixture-integrity")
        self.assertFalse(report["qualityClaim"])
        self.assertEqual(report["goldFixtures"], len(load(GOLD)))
        self.assertEqual(report["adversarialFixtures"], len(load(ADVERSARIAL)))

    def test_span_tokenizer_still_mirrors_the_swift_transcript(self):
        self.assertEqual(editplan.mirror_vector_failures(), [])

    def test_adversarial_coverage_includes_invalid_spans(self):
        adversarial = load(ADVERSARIAL)
        invalid = [record for record in adversarial if record["category"] == "invalidSpans"]
        self.assertEqual(len(invalid), 1)
        span_count = len(editplan.tokenize(invalid[0]["raw"]))
        probes = invalid[0]["probeEditPlans"]
        self.assertGreaterEqual(len(probes), 3)
        for probe in probes:
            edits = editplan.parse_plan(probe)
            self.assertEqual(editplan.bounds_violation(edits, span_count), "invalidBounds")

    def test_mirror_rejects_a_plan_that_exceeds_the_validators_change_budget(self):
        """Regression: this exact plan was certified while the runtime rejects it."""
        raw = "open the pop tart settings"
        edits = [
            {"s": 0, "e": 1, "r": "Open", "c": "capitalization"},
            {"s": 2, "e": 4, "r": "Poptart", "c": "vocabulary"},
            {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
        ]
        # max(8, ceil(26 * 0.35)) = 10, against max("open","Open") +
        # max("pop tart","Poptart") + max("",".") = 4 + 8 + 1 = 13.
        self.assertEqual(editplan.character_count(raw), 26)
        self.assertEqual(editplan.change_budget(raw), 10)
        self.assertEqual(editplan.changed_characters(edits, raw), 13)
        violation = editplan.plan_violation(edits, raw, ["Poptart"])
        self.assertIsNotNone(violation)
        self.assertTrue(violation.startswith("excessiveChange"), violation)
        # The same plan inside a corpus record must abort the whole build.
        record = dict(load(CORPUS)[0])
        record.update({"raw": raw, "clean": "Open the Poptart settings.",
                       "editPlan": {"v": 1, "e": edits}, "vocabularyTerms": ["Poptart"]})
        with self.assertRaises(ValueError) as raised:
            prepare_corpus.build(record, set())
        self.assertIn("excessiveChange", str(raised.exception))

    def test_mirror_enforces_every_validator_rule_not_only_bounds_and_category(self):
        """The rules that were missing before: what the runtime rejects must not pass."""
        long_raw = "um alpha beta gamma delta epsilon zeta eta theta"
        borrowing = dict(
            editplan.DEFAULT_TARGET_CONTEXT, textBeforeCursor="the quarterly summary"
        )
        many = [{"s": i, "e": i, "r": ".", "c": "punctuation"} for i in range(0, 18, 2)]
        cases = [
            ("tooManyEdits", long_raw, many, (), None),
            ("replacementTooLarge", long_raw,
             [{"s": 1, "e": 2, "r": "x" * 65, "c": "capitalization"}], (), None),
            ("unsafeUnicode", long_raw,
             [{"s": 1, "e": 2, "r": "Alpha\u0007", "c": "capitalization"}], (), None),
            ("reservedSpan", long_raw, [{"s": 2, "e": 4, "r": "", "c": "filler"}],
             [{"s": 1, "e": 5, "r": "", "c": "correction"}], None),
            ("copiedTargetContext", long_raw,
             [{"s": 1, "e": 2, "r": "quarterly", "c": "vocabulary"}], (), borrowing),
            # Deleting the only span empties the Dictation without removing filler.
            ("blankOutput", ".", [{"s": 0, "e": 1, "r": "", "c": "punctuation"}], (), None),
        ]
        for expected, raw, edits, reserved, context in cases:
            violation = editplan.plan_violation(edits, raw, (), reserved, context)
            self.assertIsNotNone(violation, expected)
            self.assertTrue(violation.startswith(expected), f"{expected}: got {violation}")

        # Controls: a conservative plan, and the one blank result the validator allows.
        self.assertIsNone(
            editplan.plan_violation(
                [{"s": 0, "e": 1, "r": "", "c": "filler"}], long_raw, (), (), borrowing
            )
        )
        self.assertIsNone(
            editplan.plan_violation([{"s": 0, "e": 2, "r": "", "c": "filler"}], "um uh")
        )

    def test_four_quality_dimensions_are_scored_separately(self):
        gold = load(GOLD)
        adversarial = load(ADVERSARIAL)
        vocabulary_fixtures = [
            record
            for record in gold
            if any(term in record["raw"] for term in record.get("vocabularyTerms", []))
        ]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            path.write_text(
                "".join(
                    json.dumps(record) + "\n" for record in predictions_for(gold, adversarial)
                ),
                encoding="utf-8",
            )
            report = json.loads(evaluate(["--predictions", str(path)]).stdout)

        self.assertEqual(report["mode"], "model-results")
        self.assertTrue(report["qualityClaim"])
        # Four separate figures, never averaged into one number.
        self.assertEqual(
            report["editPlanExact"], {"applicable": len(gold), "passed": len(gold) - 4}
        )
        self.assertEqual(
            report["meaningPreservation"], {"applicable": len(gold), "passed": len(gold) - 1}
        )
        self.assertEqual(
            report["vocabularyPreservation"],
            {"applicable": len(vocabulary_fixtures), "passed": len(vocabulary_fixtures) - 1},
        )
        self.assertEqual(report["contextFit"], {"applicable": len(gold), "passed": len(gold) - 1})
        self.assertEqual(
            report["adversarialSafe"],
            {"applicable": len(adversarial), "passed": len(adversarial) - 1},
        )
        self.assertGreaterEqual(len(vocabulary_fixtures), 2)

    def test_scoring_fails_closed_on_an_incomplete_prediction_file(self):
        gold = load(GOLD)
        adversarial = load(ADVERSARIAL)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            path.write_text(
                "".join(
                    json.dumps(record) + "\n"
                    for record in predictions_for(gold, adversarial)[1:]
                ),
                encoding="utf-8",
            )
            result = evaluate(["--predictions", str(path)], expect_success=False)
        self.assertNotEqual(result.returncode, 0)

    def test_training_targets_are_edit_plans_that_reproduce_the_clean_text(self):
        build_corpus()
        corpus = {record["id"]: record for record in load(CORPUS)}
        clean_texts = {record["clean"] for record in corpus.values()}
        generated = [
            record
            for name in ("train", "valid", "test")
            for record in load(ROOT / f"Training/generated/mlx/{name}.jsonl")
        ]
        self.assertEqual(len(generated), len(corpus))
        for record in generated:
            target = record["messages"][-1]
            self.assertEqual(target["role"], "assistant")
            self.assertTrue(target["content"].endswith(editplan.STOP_MARKER))
            self.assertNotIn(target["content"], clean_texts)
            edits = prepare_corpus.parse_target(target["content"])
            self.assertTrue(all(set(edit) == {"s", "e", "r", "c"} for edit in edits))

    def test_training_prompt_still_matches_the_runtime_prompt(self):
        """The corpus builder embeds CleanupPrompt's text; drift would train the wrong task."""
        if not CLEANUP_PROMPT.exists():
            self.skipTest("the Cleanup package is not present in this checkout")
        source = CLEANUP_PROMPT.read_text(encoding="utf-8")
        marker = re.search(r'stopMarker\s*=\s*"([^"]*)"', source)
        self.assertIsNotNone(marker)
        self.assertEqual(marker.group(1), editplan.STOP_MARKER)
        blocks = [block.strip() for block in re.findall(r'"""\n(.*?)\n\s*"""', source, re.S)]
        self.assertIn(prepare_corpus.SYSTEM, blocks)
        payload = [block for block in blocks if block.startswith(prepare_corpus.PREAMBLE)]
        self.assertEqual(len(payload), 1)
        self.assertIn("BEGIN_UNTRUSTED_DATA_JSON_UTF8_BYTES=", payload[0])

    def test_training_corpus_generation_is_reproducible(self):
        build_corpus()
        before = {p.name: p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        build_corpus()
        after = {p.name: p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        self.assertEqual(before, after)

    def test_corpus_build_rejects_a_plan_that_does_not_reproduce_its_clean_text(self):
        record = dict(load(CORPUS)[0])
        prepare_corpus.build(dict(record), set())
        record["clean"] = record["clean"].replace(".", "!")
        with self.assertRaises(ValueError):
            prepare_corpus.build(record, set())

    def test_corpus_build_rejects_a_model_authored_explicit_correction(self):
        record = dict(load(CORPUS)[0])
        record["editPlan"] = {"v": 1, "e": [{"s": 0, "e": 1, "r": "", "c": "correction"}]}
        with self.assertRaises(ValueError):
            prepare_corpus.build(record, set())

    def test_release_benchmark_fails_closed_without_physical_baseline_and_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    "python3",
                    "Scripts/benchmark_release.py",
                    "--runner",
                    "/missing",
                    "--model",
                    "/missing",
                    "--output",
                    str(Path(temporary) / "out.json"),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
