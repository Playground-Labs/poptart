"""The typed arm must retain every correct comparator output, not just win totals."""
import json,sys
from pathlib import Path
sys.path.insert(0,'Evals')
from run import validate_prediction
root=Path(__file__).resolve().parent
load=lambda name:[json.loads(x) for x in (root/name).read_text().splitlines()]
fixtures=load('evaluation.jsonl');assert len(fixtures)==91
ids={f['id'] for f in fixtures};assert len(ids)==91
arms={};summary={}
for arm in ('retainedBaseline','range','typed'):
 rows=load(arm+'-predictions.jsonl');indexed={r['id']:r for r in rows}
 assert len(rows)==len(indexed)==91 and set(indexed)==ids
 for row in rows:validate_prediction(row['id'],row)
 arms[arm]=indexed
 groups={}
 for group in sorted({f['group'] for f in fixtures}):
  selected=[f for f in fixtures if f['group']==group]
  groups[group]={'count':len(selected),'exact':sum(indexed[f['id']]['output']==f['expected'] for f in selected)}
 summary[arm]={'totalExact':sum(v['exact'] for v in groups.values()),'groups':groups}
comparisons={}
for reference in ('retainedBaseline','range'):
 regressions=[f['id'] for f in fixtures if arms[reference][f['id']]['output']==f['expected'] and arms['typed'][f['id']]['output']!=f['expected']]
 improvements=[f['id'] for f in fixtures if arms[reference][f['id']]['output']!=f['expected'] and arms['typed'][f['id']]['output']==f['expected']]
 comparisons[reference]={'regressions':regressions,'improvements':improvements}
targets=['newContext','diagnostic-statement','diagnostic-filler','diagnostic-context-mid','diagnostic-context-new']
targeted=any(all(summary['typed']['groups'][g]['exact']>summary[reference]['groups'][g]['exact'] for reference in comparisons) for g in targets)
eligible=all(not v['regressions'] and summary['typed']['totalExact']>summary[k]['totalExact'] for k,v in comparisons.items()) and targeted
result={'releaseQualified':False,'scope':'Python feasibility; native parity and broad safety required before promotion','arms':summary,'typedComparedWith':comparisons,'targetedGroupImprovementOverBoth':targeted,'typedEligibleForBroaderEvaluation':eligible}
(root/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
