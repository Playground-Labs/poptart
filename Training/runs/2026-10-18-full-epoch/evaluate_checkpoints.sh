#!/bin/sh
# Run from repository root with fresh output directories; adapters are frozen in inputs.json.
set -eu
py=.context/cleanup-model/venv/bin/python
root=Training/runs/2026-10-18-full-epoch
for step in 131 262; do
  dest=.context/cleanup-round10/step-$step
  "$py" -m mlx_lm fuse --model .context/cleanup-model/base --adapter-path "$dest/adapters" --save-path "$dest/fused"
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/fused/"
  "$py" -m mlx_lm convert --hf-path "$dest/fused" --mlx-path "$dest/candidate-4bit" -q --q-bits 4 --q-group-size 64 --q-mode affine
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/candidate-4bit/"
done
for step in 131 262; do
  swift run --package-path Packages/Cleanup CleanupEvaluation ".context/cleanup-round10/step-$step/candidate-4bit" "$root/validation.jsonl" "$root/step-$step.jsonl"
done
