"""Compare frozen validation outputs using the pre-inference protocol."""
import json
import sys
import unicodedata
from pathlib import Path
sys.path.insert(0, 'Training')
from compare_swift_candidates import compare

root = Path('Training/runs/2026-10-18-full-epoch')
def load(name):
    return [json.loads(line) for line in (root/name).read_text().splitlines()]
fixtures = [dict(r,expected=r['clean']) for r in load('validation.jsonl')]
assert len(fixtures)==47 and all(r['split']=='valid' for r in fixtures)
groups = {'originalValidation':[r for r in fixtures if not r['id'].startswith('round8-')],
          'expandedValidation':[r for r in fixtures if r['id'].startswith('round8-')]}
assert len(groups['originalValidation'])==29 and len(groups['expandedValidation'])==18
baseline = [json.loads(line) for line in Path('Training/runs/2026-10-17-round9/step-200.jsonl').read_text().splitlines()]
assert all(not any(unicodedata.category(c)=='Cc' and c not in '\t\n\r\v\f\x85' for c in r['raw']) for r in fixtures)
results=[]
for step,name in [(0,None),(131,'step-131.jsonl'),(262,'step-262.jsonl')]:
    report=compare(groups,baseline,baseline if name is None else load(name))
    with (root/f'comparison-{step}.json').open('x') as f:f.write(json.dumps(report,indent=2)+'\n')
    result={'additionalSteps':step,
            'exactOutput':sum(g['candidate']['exactOutput'] for g in report['groups'].values()),
            'acceptedPlans':sum(g['candidate']['acceptedPlans'] for g in report['groups'].values()),
            'improved':[i for g in report['groups'].values() for i in g['improved']],
            'regressed':[i for g in report['groups'].values() for i in g['regressed']]}
    results.append(result)
ranked=sorted(results,key=lambda r:(-r['exactOutput'],r['additionalSteps']))
summary={'releaseQualified':False,'validationCount':47,'ranking':ranked,
         'outputSelectedAdditionalSteps':ranked[0]['additionalSteps'],
         'interpretation':'Diagnostic ranking on validation only; separate dimensions and regressions require review. This is the predeclared output-based selection, not release qualification.'}
with (root/'ranking.json').open('x') as f:f.write(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
