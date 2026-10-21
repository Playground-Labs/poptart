"""Apply the frozen retention rule to complete Swift validation predictions."""
import json, sys
from pathlib import Path
sys.path.insert(0, 'Training')
from compare_swift_candidates import compare
import prepare_corpus as p
root = Path(__file__).resolve().parent
load = lambda name: [json.loads(x) for x in (root/name).read_text().splitlines()]
fixtures = [dict(r, expected=r['clean']) for r in load('validation.jsonl')]
groups = {'existing': [r for r in fixtures if not r['id'].startswith('targeted-')],
          'fresh': [r for r in fixtures if r['id'].startswith('targeted-')]}
assert len(groups['existing']) == 47 and len(groups['fresh']) == 8
baseline = load('baseline-validation.jsonl')
results = []
for step in (0, 40, 80):
    rows = baseline if step == 0 else load(f'step-{step}-validation.jsonl')
    report = compare(groups, baseline, rows)
    indexed = {r['id']: r for r in rows}
    categories = {}
    for name, predicate in {
        'vocabulary': lambda r: any(e['c'] == 'vocabulary' for e in r['editPlan']['e']),
        'internalFiller': lambda r: any(e['c'] == 'filler' and 0 < e['s'] < e['e'] < len(p.editplan.tokenize(r['raw'])) for e in r['editPlan']['e']),
        'trailingFiller': lambda r: any(e['c'] == 'filler' and e['e'] == len(p.editplan.tokenize(r['raw'])) for e in r['editPlan']['e']),
        'repetition': lambda r: any(e['c'] == 'repetition' for e in r['editPlan']['e']),
        'noOp': lambda r: not r['editPlan']['e'],
    }.items():
        selected = [r for r in fixtures if predicate(r)]
        categories[name] = {'count':len(selected), 'exact':sum(indexed[r['id']]['output'] == r['expected'] for r in selected)}
    report['categories'] = categories
    (root/f'comparison-{step}.json').write_text(json.dumps(report, indent=2)+'\n')
    old = report['groups']['existing']['candidate']['exactOutput']
    new = report['groups']['fresh']['candidate']['exactOutput']
    regressions = report['groups']['existing']['regressed']
    results.append({'steps':step,'existingExact':old,'freshExact':new,'totalExact':old+new,
                    'regressions':regressions,'eligible':step == 0 or (old+new > 42 and not regressions)})
assert results[0]['existingExact'] == 38 and results[0]['totalExact'] == 42, 'Baseline changed; stop selection'
ranked = sorted((r for r in results if r['eligible']), key=lambda r:(-r['totalExact'],r['steps']))
summary = {'releaseQualified':False,'candidates':results,'selectedSteps':ranked[0]['steps']}
(root/'ranking.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
