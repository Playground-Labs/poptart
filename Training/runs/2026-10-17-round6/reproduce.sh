#!/bin/sh
# Run from repository root. Use fresh output directories for a reproduction.
set -eu
py=.context/cleanup-model/venv/bin/python
$py - <<'PY'
import json,sys,shutil
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as corpus
out=Path('.context/cleanup-round6/data')
out.mkdir(parents=True,exist_ok=True)
seen=set()
records=[json.loads(line) for line in Path('Training/runs/2026-10-17-round4/training-sample.jsonl').read_text().splitlines()]
(out/'train.jsonl').write_text(''.join(json.dumps(corpus.build(row,seen))+'\n' for row in records))
for name in ['valid','test']:
    shutil.copyfile(f'Training/generated/mlx/{name}.jsonl',out/f'{name}.jsonl')
PY
$py -u -m mlx_lm lora \
  --config Training/runs/2026-10-17-round6/training-config.yaml \
  --model .context/cleanup-model/base --data .context/cleanup-round6/data \
  --iters 200 --max-seq-length 512 \
  --resume-adapter-file .context/cleanup-round4/selected-adapters/adapters.safetensors \
  --adapter-path .context/cleanup-round6/adapters
