"""Evaluate the frozen post-selection gates; safety still requires recorded review."""
import json, sys
from pathlib import Path
sys.path.insert(0, 'Training')
from compare_swift_candidates import compare
root=Path(__file__).resolve().parent
load=lambda n:[json.loads(x) for x in (root/n).read_text().splitlines()]
fixtures=load('evaluation.jsonl')
groups={'historical':[], 'adversarial':[], 'fresh':[]}
for r in fixtures:
    group='adversarial' if r['id'].startswith('adv-') else 'fresh' if r['id'].startswith('targeted-') else 'historical'
    groups[group].append(r if group=='adversarial' else dict(r,expected=r.get('expected',r.get('clean'))))
assert {k:len(v) for k,v in groups.items()}=={'historical':68,'adversarial':11,'fresh':16}
baseline=load('baseline-evaluation.jsonl');candidate=load('step-80-evaluation.jsonl')
report=compare(groups,baseline,candidate)
assert report['groups']['historical']['baseline']['exactOutput']==49, 'Historical baseline changed'
quality=(not report['groups']['historical']['regressed'] and report['groups']['fresh']['candidate']['exactOutput']>report['groups']['fresh']['baseline']['exactOutput'])
report['quantitativeGatePassed']=quality
report['safetyReviewRequired']=True
(root/'evaluation-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
b={r['id']:r for r in baseline};c={r['id']:r for r in candidate}
changes=[]
for f in fixtures:
    identifier=f['id']
    if b[identifier]['output']!=c[identifier]['output'] or identifier.startswith('adv-'):
        changes.append({'id':identifier,'raw':f['raw'],'expected':f.get('expected',f.get('clean')),
                        'baseline':b[identifier],'candidate':c[identifier]})
(root/'changed-outputs.json').write_text(json.dumps(changes,indent=2)+'\n')
print(json.dumps({'quantitativeGatePassed':quality,'groups':{k:{'baseline':v['baseline'].get('exactOutput'),'candidate':v['candidate'].get('exactOutput'),'regressed':v.get('regressed')} for k,v in report['groups'].items()}}))
