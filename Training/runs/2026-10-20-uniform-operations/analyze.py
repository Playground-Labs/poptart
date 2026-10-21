"""Describe the frozen candidate and diagnostic; never change selection gates."""
import json
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parent
def load(name):
    return [json.loads(line) for line in (root / name).read_text().splitlines()]

fixtures = {row['id']: row for row in load('evaluation.jsonl')}
arms = {}
summary = {}
for arm in ('retainedBaseline', 'range', 'uniform', 'uniform-fp'):
    rows = load(arm + '-predictions.jsonl')
    indexed = {row['id']: row for row in rows}
    assert len(rows) == len(indexed) == 91 and indexed.keys() == fixtures.keys()
    arms[arm] = indexed
    operations = Counter()
    categories = Counter()
    for row in rows:
        for operation in row.get('uniformPlan', {}).get('e', []):
            operations[operation['o']] += 1
            if operation['o'] == 'edit':
                categories[operation['c']] += 1
    summary[arm] = {
        'exact': sum(row['output'] == fixtures[row['id']]['expected'] for row in rows),
        'outcomes': dict(Counter(row['outcome'] for row in rows)),
        'compiledPlans': sum('uniformPlan' in row for row in rows),
        'operationsInCompiledPlans': dict(operations),
        'editCategoriesInCompiledPlans': dict(categories),
        'rejections': dict(Counter(row['rejection'] for row in rows if row.get('rejection') is not None)),
    }
changed = []
for key, fixture in fixtures.items():
    q, fp = arms['uniform'][key], arms['uniform-fp'][key]
    if (q['output'], q['outcome']) != (fp['output'], fp['outcome']):
        changed.append({'id': key, 'raw': fixture['raw'], 'expected': fixture['expected'],
                        'fourBit': q['output'], 'fullPrecision': fp['output'],
                        'fourBitOutcome': q['outcome'], 'fullPrecisionOutcome': fp['outcome']})
result = {'releaseQualified': False, 'arms': summary,
          'quantizationComparison': {
              'changedOutputOrOutcome': changed,
              'fullPrecisionOnlyCorrect': [k for k in fixtures if arms['uniform-fp'][k]['output'] == fixtures[k]['expected'] and arms['uniform'][k]['output'] != fixtures[k]['expected']],
              'fourBitOnlyCorrect': [k for k in fixtures if arms['uniform'][k]['output'] == fixtures[k]['expected'] and arms['uniform-fp'][k]['output'] != fixtures[k]['expected']],
          }}
(root / 'diagnostic-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(summary, indent=2))
