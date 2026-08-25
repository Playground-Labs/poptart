#!/usr/bin/env python3
import json, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class ToolingTests(unittest.TestCase):
    def test_fixture_integrity_is_deterministic_and_not_a_quality_claim(self):
        first = subprocess.run(["python3", "Evals/run.py"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
        second = subprocess.run(["python3", "Evals/run.py"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
        self.assertEqual(first, second)
        report = json.loads(first)
        self.assertEqual(report["mode"], "fixture-integrity")
        self.assertFalse(report["qualityClaim"])

    def test_training_corpus_generation_is_reproducible(self):
        subprocess.run(["python3", "Training/prepare_corpus.py"], cwd=ROOT, check=True, capture_output=True)
        before = {p.name:p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        subprocess.run(["python3", "Training/prepare_corpus.py"], cwd=ROOT, check=True, capture_output=True)
        after = {p.name:p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        self.assertEqual(before, after)

    def test_release_benchmark_fails_closed_without_physical_baseline_and_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(["python3", "Scripts/benchmark_release.py", "--runner", "/missing", "--model", "/missing", "--output", str(Path(temporary)/"out.json")], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

if __name__ == "__main__": unittest.main()
