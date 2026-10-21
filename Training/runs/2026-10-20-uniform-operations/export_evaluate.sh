#!/bin/sh
set -eu
root=Training/runs/2026-10-20-uniform-operations
py=.context/cleanup-model/venv/bin/python
dest=.context/cleanup-uniform
"$py" -m mlx_lm fuse --model .context/cleanup-model/base --adapter-path "$dest/adapters" --save-path "$dest/fused"
cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/fused/"
"$py" -m mlx_lm convert --hf-path "$dest/fused" --mlx-path "$dest/candidate-4bit" -q --q-bits 4 --q-group-size 64 --q-mode affine
cp .context/cleanup-model/base/tokenizer*.json .context/cleanup-model/base/chat_template.jinja .context/cleanup-model/base/LICENSE "$dest/candidate-4bit/"
"$py" "$root/evaluate.py" uniform "$dest/candidate-4bit" > "$root/evaluation.log" 2>&1
python3 "$root/score.py"
