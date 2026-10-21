"""Validate complete native predictions and apply the frozen diagnostic criteria."""
import json,sys
from pathlib import Path
sys.path.insert(0,'Training')
from compare_swift_candidates import evaluation
root=Path(__file__).resolve().parent
load=lambda n:[json.loads(x) for x in (root/n).read_text().splitlines()]
fixtures=load('fixtures.jsonl');groups={}
for f in fixtures:groups.setdefault(f['group'],[]).append(f)
base=load('baseline.jsonl');baseline={r['id']:r for r in base}
assert len(fixtures)==24
results={}
for arm in ('baseline','boundary','context'):
 rows=base if arm=='baseline' else load(arm+'.jsonl')
 suffix='' if arm=='baseline' else (root/(arm+'.txt')).read_text()
 indexed={r['id']:r for r in rows}
 assert len(indexed)==len(rows)==24 and set(indexed)==set(baseline)=={f['id'] for f in fixtures}
 for row in rows:evaluation.validate_prediction(row['id'],row)
 report={'releaseQualified':False,'groups':{}}
 for name,records in groups.items():
  report['groups'][name]={
   'count':len(records),
   'baseline':{'exactOutput':sum(baseline[f['id']]['output']==f['expected'] for f in records)},
   'candidate':{'exactOutput':sum(indexed[f['id']]['output']==f['expected'] for f in records)},
   'regressed':[f['id'] for f in records if baseline[f['id']]['output']==f['expected'] and indexed[f['id']]['output']!=f['expected']],
   'improved':[f['id'] for f in records if baseline[f['id']]['output']!=f['expected'] and indexed[f['id']]['output']==f['expected']]}

 for row in rows:
  # Swift multiline system literal may carry outer whitespace; its actual prefix must
  # remain exactly the same across arms and suffix bytes must be preserved.
  expected=baseline[row['id']]['systemInstruction']+suffix
  assert row['systemInstruction']==expected
  assert row['prompt']==baseline[row['id']]['prompt']
  if suffix:assert row['inputTokens']>baseline[row['id']]['inputTokens']
 exact=sum(g['candidate']['exactOutput'] for g in report['groups'].values())
 old=sum(g['baseline']['exactOutput'] for g in report['groups'].values())
 lost=[identifier for g in report['groups'].values() for identifier in g['regressed']]
 target=['statement','filler','repetition'] if arm=='boundary' else ['context-mid','context-new']
 targeted=sum(report['groups'][k]['candidate']['exactOutput']-report['groups'][k]['baseline']['exactOutput'] for k in target)
 report.update(totalExact=exact,regressions=lost,promising=arm!='baseline' and exact>old and not lost and targeted>0)
 results[arm]=report
(root/'comparison.json').write_text(json.dumps(results,indent=2)+'\n')
for arm,report in results.items():
 print(json.dumps({'arm':arm,'exact':report['totalExact'],'regressions':report['regressions'],'promising':report['promising'],'groups':{k:v['candidate']['exactOutput'] for k,v in report['groups'].items()}}))
