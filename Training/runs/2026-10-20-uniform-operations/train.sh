#!/bin/sh
set -eu
root=Training/runs/2026-10-20-uniform-operations
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
 --config "$root/training-config.yaml" --model .context/cleanup-model/base \
 --data .context/cleanup-uniform/mlx \
 --resume-adapter-file .context/cleanup-round8/adapters/0000200_adapters.safetensors \
 --adapter-path .context/cleanup-uniform/adapters > "$root/training.log" 2>&1
