#!/bin/sh
# Run from the repository root on an existing Linux NVIDIA host.
set -eu
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 BASE_MODEL START_ADAPTER NEW_OUTPUT_DIRECTORY" >&2
  exit 2
fi
model=$1
adapter=$2
output=$3
[ -d "$model" ] && [ -f "$adapter" ] || { echo 'Missing local model or adapter' >&2; exit 2; }
[ ! -e "$output" ] || { echo 'Output must not exist' >&2; exit 2; }
python - <<'PY'
import platform
from importlib.metadata import version
import mlx.core as mx
assert platform.system() == 'Linux', 'This benchmark requires Linux/CUDA'
assert version('mlx') == '0.32.3' and version('mlx-lm') == '0.31.3', 'Use the documented pinned packages'
assert mx.cuda.is_available(), 'MLX CUDA backend unavailable'
mx.set_default_device(mx.gpu)
mx.eval(mx.ones((32, 32)) @ mx.ones((32, 32)))
print('MLX CUDA smoke check passed')
PY
mkdir -p "$output"
nvidia-smi > "$output/nvidia-smi.txt"
python -m pip freeze > "$output/packages.txt"
# A throughput probe only: validation is reduced to one batch and outputs are not candidates.
python -u -m mlx_lm lora \
  --config Training/runs/2026-10-18-full-epoch/training-config.yaml \
  --model "$model" --data Training/generated/mlx \
  --resume-adapter-file "$adapter" --adapter-path "$output/adapters" \
  --iters 20 --val-batches 1 --steps-per-eval 20 --save-every 20 \
  > "$output/training.log" 2>&1
cat "$output/training.log"
