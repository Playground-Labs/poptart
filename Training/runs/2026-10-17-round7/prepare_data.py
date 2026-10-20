"""Retain every training record; give seven fixed failures eight total copies."""
import hashlib
import json
import shutil
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as corpus
root = Path('Training/runs/2026-10-17-round7')
out = Path('.context/cleanup-round7/data')
out.mkdir(parents=True, exist_ok=False)
records = [json.loads(line) for line in corpus.SOURCE.read_text().splitlines()]
training = [r for r in records if r['split'] == 'train']
sample = {r['id']: r for r in map(json.loads, Path('Training/runs/2026-10-17-round4/training-sample.jsonl').read_text().splitlines())}
baseline = [json.loads(line) for line in Path('Training/runs/2026-10-17-round5/baseline.jsonl').read_text().splitlines()]
failures = [r['id'] for r in baseline if r['output'] != sample[r['id']]['clean']]
assert len(training) == 172 and len(failures) == 7
seen = set()
built = {r['id']: corpus.build(r, seen) for r in training}
weighted = [built[r['id']] for r in training] + [built[i] for i in failures] * 7
assert len(weighted) == 221
(out/'train.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in weighted))
for name in ['valid', 'test']:
    shutil.copyfile(f'Training/generated/mlx/{name}.jsonl', out/f'{name}.jsonl')
paths = [corpus.SOURCE, out/'train.jsonl', out/'valid.jsonl', Path(__file__), Path('.context/cleanup-round4/selected-adapters/adapters.safetensors')]
(root/'inputs.json').write_text(json.dumps({'releaseQualified':False,'uniqueTrainingRecords':172,'weightedTrainingRecords':221,'extraCopiesPerFailure':7,'failureIDs':failures,'inputsSHA256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}},indent=2)+'\n')
print('Validated 172 unique training records, 221 weighted rows; validation unchanged.')
