#!/bin/sh
set -eu
root=Training/runs/2026-10-20-typed-operations
py=.context/cleanup-model/venv/bin/python
for arm in range typed; do
  dest=.context/cleanup-typed/$arm
  "$py" -m mlx_lm fuse --model .context/cleanup-model/base --adapter-path "$dest/adapters" --save-path "$dest/fused"
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/fused/"
  "$py" -m mlx_lm convert --hf-path "$dest/fused" --mlx-path "$dest/candidate-4bit" -q --q-bits 4 --q-group-size 64 --q-mode affine
  cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/candidate-4bit/"
done
"$py" "$root/evaluate.py" retainedBaseline .context/cleanup-round9/step-200/candidate-4bit > "$root/retainedBaseline-evaluation.log" 2>&1
for arm in range typed; do
  "$py" "$root/evaluate.py" "$arm" ".context/cleanup-typed/$arm/candidate-4bit" > "$root/$arm-evaluation.log" 2>&1
done
python3 "$root/score.py"
