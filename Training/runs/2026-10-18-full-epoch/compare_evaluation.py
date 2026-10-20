"""Compare fixed development groups, preserving individual quality dimensions."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
from compare_swift_candidates import compare

root = Path('Training/runs/2026-10-18-full-epoch')
def load(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines()]
def expected(rows):
    return [dict(row, expected=row['clean']) for row in rows]
groups = {
    'gold': load('Evals/fixtures/gold.jsonl'),
    'adversarial': load('Evals/fixtures/adversarial.jsonl'),
    'originalHoldout': expected([r for r in load('Training/data/corpus.jsonl') if r['split']=='test']),
    'round2Holdout': expected(load('Training/data/round2-holdout.jsonl')),
    'round3Holdout': expected(load('Training/data/round3-holdout.jsonl')),
    'round6Holdout': expected(load('Training/runs/2026-10-17-round6/unseen.jsonl')),
    'round8Evaluation': expected(load('Training/data/round8-holdout.jsonl')),
}
candidate = load(root/'evaluation-predictions.jsonl')
references = {'evaluation': load('Training/runs/2026-10-17-control-guard/predictions.jsonl')}
for name, rows in references.items():
    report = compare(groups, rows, candidate)
    with (root/f'{name}-comparison.json').open('x') as f:
        f.write(json.dumps(report,indent=2)+'\n')
    print(name, json.dumps({group:{label:result[label].get('exactOutput',result[label]['metrics']['adversarialSafe']) for label in ['baseline','candidate']} for group,result in report['groups'].items()}))
