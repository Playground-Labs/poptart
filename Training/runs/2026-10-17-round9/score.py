"""Compare frozen validation outputs using the pre-inference protocol."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
from compare_swift_candidates import compare

root = Path('Training/runs/2026-10-17-round9')
def load(name):
    return [json.loads(line) for line in (root/name).read_text().splitlines()]
fixtures = [dict(r,expected=r['clean']) for r in load('validation.jsonl')]
assert len(fixtures)==47 and all(r['split']=='valid' for r in fixtures)
groups = {'originalValidation':[r for r in fixtures if not r['id'].startswith('round8-')],
          'expandedValidation':[r for r in fixtures if r['id'].startswith('round8-')]}
assert len(groups['originalValidation'])==29 and len(groups['expandedValidation'])==18
baseline = load('baseline.jsonl')
results=[]
for step,name in [(0,'baseline.jsonl'),(100,'step-100.jsonl'),(200,'step-200.jsonl')]:
    report=compare(groups,baseline,load(name))
    with (root/f'comparison-{step}.json').open('x') as f:f.write(json.dumps(report,indent=2)+'\n')
    result={'additionalSteps':step,'loggedValidationLoss':{0:.031,100:.031,200:.034}[step],
            'exactOutput':sum(g['candidate']['exactOutput'] for g in report['groups'].values()),
            'acceptedPlans':sum(g['candidate']['acceptedPlans'] for g in report['groups'].values()),
            'improved':[i for g in report['groups'].values() for i in g['improved']],
            'regressed':[i for g in report['groups'].values() for i in g['regressed']]}
    results.append(result)
ranked=sorted(results,key=lambda r:(-r['exactOutput'],r['additionalSteps']))
summary={'releaseQualified':False,'validationCount':47,'ranking':ranked,
         'outputSelectedAdditionalSteps':ranked[0]['additionalSteps'],
         'originalLossSelectedAdditionalSteps':0,
         'interpretation':'Diagnostic ranking on validation only; separate dimensions and regressions require review. This does not change the original run selection or qualify a release.'}
with (root/'ranking.json').open('x') as f:f.write(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
