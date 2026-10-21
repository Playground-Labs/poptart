#!/bin/sh
set -eu
root=Training/runs/2026-10-20-balanced-rehearsal
python3 -c 'import json; assert json.load(open("Training/runs/2026-10-20-balanced-rehearsal/ranking.json"))["selectedSteps"] == 80'
swift run --package-path Packages/Cleanup CleanupEvaluation .context/cleanup-round9/step-200/candidate-4bit "$root/evaluation.jsonl" "$root/baseline-evaluation.jsonl"
swift run --package-path Packages/Cleanup CleanupEvaluation .context/cleanup-balanced/step-80/candidate-4bit "$root/evaluation.jsonl" "$root/step-80-evaluation.jsonl"
