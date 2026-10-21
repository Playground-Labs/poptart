"""Replay the three captured punctuation regressions against the evaluator mirror."""
import json,sys
from pathlib import Path
sys.path.insert(0,'Evals')
import editplan
root=Path('Training/runs/2026-10-20-balanced-rehearsal')
fixtures={r['id']:r for r in map(json.loads,(root/'evaluation.jsonl').read_text().splitlines())}
predictions={r['id']:r for r in map(json.loads,(root/'step-80-evaluation.jsonl').read_text().splitlines())}
ids=['round2-statement-013','round6-unseen-001','round6-unseen-002']
wrong=[]
for identifier in ids:
 f=fixtures[identifier];p=predictions[identifier];edits=editplan.parse_plan(p['editPlan'])
 assert editplan.plan_violation(edits,f['raw']) is None
 output=editplan.resolve(f['raw'],edits)
 assert output==p['output']
 count=len(editplan.tokenize(f['raw']))
 fixed=[dict(e,s=count,e=count) for e in edits]
 assert editplan.resolve(f['raw'],fixed)==f['clean']
 wrong.append(output!=f['clean'])
 print(json.dumps({'id':identifier,'spans':count,'generatedBoundary':edits[0]['s'],'output':output,'correctBoundaryOutput':editplan.resolve(f['raw'],fixed)}))
assert all(wrong)
if '--require-correct' in sys.argv:sys.exit(1)
