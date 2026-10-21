#!/bin/sh
set -eu
root=Training/runs/2026-10-20-span-context
model=.context/cleanup-balanced/step-80/candidate-4bit
swift run --package-path Packages/Cleanup CleanupEvaluation "$model" "$root/fixtures.jsonl" "$root/baseline.jsonl"
for variant in boundary context; do
  swift run --package-path Packages/Cleanup CleanupEvaluation "$model" "$root/fixtures.jsonl" "$root/$variant.jsonl" "$root/$variant.txt"
done
