#!/usr/bin/env python3
"""Opt-in regression for stopping local MLX generation and exiting cleanly."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path, help="local exported Cleanup model directory")
    args = parser.parse_args()
    model = args.model.resolve(strict=True)
    subprocess.run(
        ["swift", "build", "--package-path", str(ROOT / "Packages/Cleanup"),
         "--product", "CleanupEvaluation"], check=True, cwd=ROOT,
    )
    fixture = (ROOT / "Evals/fixtures/gold.jsonl").read_text().splitlines()[0]
    expected_id = json.loads(fixture)["id"]
    with tempfile.TemporaryDirectory(prefix="cleanup-lifecycle-") as temporary:
        directory = Path(temporary)
        fixtures = directory / "fixture.jsonl"
        fixtures.write_text(fixture + "\n")
        # A valid result file alone missed the original teardown SIGSEGV.
        for attempt in range(3):
            output = directory / f"result-{attempt}.jsonl"
            result = subprocess.run(
                ["swift", "run", "--skip-build", "--package-path",
                 str(ROOT / "Packages/Cleanup"), "CleanupEvaluation",
                 str(model), str(fixtures), str(output)],
                check=True, capture_output=True, text=True, timeout=120, cwd=ROOT,
            )
            rows = [json.loads(line) for line in output.read_text().splitlines()]
            assert len(rows) == 1 and rows[0]["id"] == expected_id
            assert "<END_PLAN>" in rows[0]["generated"], "fixture must exercise early stop"
            assert "wrote 1 records" in result.stdout
    print("Swift MLX shutdown regression passed: 3 clean process exits")


if __name__ == "__main__":
    main()
