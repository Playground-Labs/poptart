#!/usr/bin/env python3
"""Compare saved Swift predictions on the fixed Cleanup development sets."""

import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Evals"))
import run as evaluation


def compare(groups, baseline, candidate):
    expected_ids = [row["id"] for rows in groups.values() for row in rows]
    if len(set(expected_ids)) != len(expected_ids):
        raise ValueError("duplicate fixture IDs")
    indexed = []
    for predictions in (baseline, candidate):
        by_id = {row["id"]: row for row in predictions}
        if len(by_id) != len(predictions) or set(by_id) != set(expected_ids):
            raise ValueError("prediction IDs must match all fixtures exactly")
        for identifier, row in by_id.items():
            evaluation.validate_prediction(identifier, row)
        indexed.append(by_id)
    result = {"releaseQualified": False, "groups": {}}
    for name, rows in groups.items():
        group = {}
        for label, predictions in zip(("baseline", "candidate"), indexed):
            adversarial = name == "adversarial"
            group[label] = {
                "count": len(rows),
                "acceptedPlans": sum(predictions[r["id"]]["outcome"] == "cleaned" for r in rows),
                "metrics": evaluation.score([] if adversarial else rows,
                                            rows if adversarial else [], predictions),
            }
            if not adversarial:
                group[label]["exactOutput"] = sum(
                    predictions[r["id"]]["output"] == r["expected"] for r in rows)
        if name != "adversarial":
            transitions = {"improved": [], "regressed": []}
            for row in rows:
                before, after = [p[row["id"]]["output"] == row["expected"] for p in indexed]
                if before != after:
                    transitions["improved" if after else "regressed"].append(row["id"])
            group.update(transitions)
        result["groups"][name] = group
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extra-holdout", type=Path, help="Additional frozen JSONL holdout")
    args = parser.parse_args()
    groups = {
        "gold": evaluation.load(ROOT / "Evals/fixtures/gold.jsonl"),
        "adversarial": evaluation.load(ROOT / "Evals/fixtures/adversarial.jsonl"),
        "originalHoldout": [dict(r, expected=r["clean"]) for r in evaluation.load(
            ROOT / "Training/data/corpus.jsonl") if r["split"] == "test"],
        "round2Holdout": [dict(r, expected=r["clean"]) for r in evaluation.load(
            ROOT / "Training/data/round2-holdout.jsonl")],
    }
    if args.extra_holdout:
        groups["extraHoldout"] = [dict(r, expected=r["clean"])
                                  for r in evaluation.load(args.extra_holdout)]
    report = compare(groups, evaluation.load(args.baseline), evaluation.load(args.candidate))
    with args.output.open("x") as output:
        output.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
