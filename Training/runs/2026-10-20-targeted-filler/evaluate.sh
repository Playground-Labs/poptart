#!/bin/sh
set -eu
root=Training/runs/2026-10-20-targeted-filler
py=.context/cleanup-model/venv/bin/python
swift run --package-path Packages/Cleanup CleanupEvaluation .context/cleanup-round9/step-200/candidate-4bit "$root/validation.jsonl" "$root/baseline-validation.jsonl"
for step in 40 80; do
  dest=.context/cleanup-targeted/step-$step
  mkdir -p "$dest/adapters"
  checkpoint=$(printf '%07d' "$step")
  cp ".context/cleanup-targeted/adapters/${checkpoint}_adapters.safetensors" "$dest/adapters/adapters.safetensors"
  cp .context/cleanup-targeted/adapters/adapter_config.json "$dest/adapters/"
  "$py" -m mlx_lm fuse --model .context/cleanup-model/base --adapter-path "$dest/adapters" --save-path "$dest/fused"
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/fused/"
  "$py" -m mlx_lm convert --hf-path "$dest/fused" --mlx-path "$dest/candidate-4bit" -q --q-bits 4 --q-group-size 64 --q-mode affine
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/candidate-4bit/"
  swift run --package-path Packages/Cleanup CleanupEvaluation "$dest/candidate-4bit" "$root/validation.jsonl" "$root/step-$step-validation.jsonl"
done
python3 "$root/score.py"
