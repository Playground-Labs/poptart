import json,sys
from pathlib import Path
sys.path.insert(0,'Training')
from compare_swift_candidates import compare
root=Path('Training/runs/2026-10-20-targeted-filler')
def load(name):return [json.loads(l) for l in (root/name).read_text().splitlines()]
fixtures=[dict(r,expected=r['clean']) for r in load('validation.jsonl')]
groups={'existing':[r for r in fixtures if not r['id'].startswith('targeted-')],'fresh':[r for r in fixtures if r['id'].startswith('targeted-')]}
assert len(groups['existing'])==47 and len(groups['fresh'])==8
baseline=load('baseline-validation.jsonl');results=[]
for step in (0,40,80):
 rows=baseline if step==0 else load(f'step-{step}-validation.jsonl')
 report=compare(groups,baseline,rows)
 (root/f'comparison-{step}.json').write_text(json.dumps(report,indent=2)+'\n')
 old=report['groups']['existing']['candidate']['exactOutput'];new=report['groups']['fresh']['candidate']['exactOutput']
 results.append({'steps':step,'existingExact':old,'freshExact':new,'totalExact':old+new,'eligible':old>=38})
assert results[0]['existingExact']==38,'Baseline changed: stop selection and investigate'
ranked=sorted([r for r in results if r['eligible']],key=lambda r:(-r['totalExact'],r['steps']))
summary={'releaseQualified':False,'candidates':results,'selectedSteps':ranked[0]['steps']}
(root/'ranking.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
