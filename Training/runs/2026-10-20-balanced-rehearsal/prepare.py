import hashlib, json, sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as p
read = lambda path: [json.loads(x) for x in Path(path).read_text().splitlines()]
source = Path('Training/runs/2026-10-20-targeted-filler')
rows = [r for r in read('Training/data/corpus.jsonl') if r['split'] == 'train']
cat = lambda r, c: any(e['c'] == c for e in r['editPlan']['e'])
buckets = [
    ('vocabulary', 16, lambda r: cat(r, 'vocabulary')),
    ('internal-filler', 4, lambda r: any(
        e['c'] == 'filler' and 0 < e['s'] < e['e'] < len(p.editplan.tokenize(r['raw']))
        for e in r['editPlan']['e'])),
    ('repetition', 4, lambda r: cat(r, 'repetition')),
    ('empty', 2, lambda r: not r['editPlan']['e']),
    ('question', 2, lambda r: any(e['c'] == 'punctuation' and e['r'] == '?'
                                for e in r['editPlan']['e'])),
    ('reserved', 2, lambda r: bool(r.get('reservedEdits'))),
    ('context', 2, lambda r: bool(r.get('targetContext'))),
]
picked, manifest = [], {}
for name, count, predicate in buckets:
    pool = sorted((r for r in rows if predicate(r) and r not in picked), key=lambda r:
        hashlib.sha256(('20261020-balanced:' + r['id']).encode()).hexdigest())
    assert len(pool) >= count, name
    selected = pool[:count]
    picked.extend(selected)
    manifest[name] = [r['id'] for r in selected]
training = picked + [r for r in read(source/'new-examples.jsonl') if r['split'] == 'train']
validation = read(source/'validation.jsonl')
assert len(training) == 80 and len(validation) == 55
seen = set()
train_messages = [p.build(r, seen) for r in training]
valid_messages = [p.build(r, seen) for r in validation]
assert not {r['raw'] for r in training} & {r['raw'] for r in validation}
out = Path('.context/cleanup-balanced')
out.mkdir(exist_ok=False)
(out/'mlx').mkdir()
for path, records in [('training.jsonl', training), ('validation.jsonl', validation),
                      ('mlx/train.jsonl', train_messages), ('mlx/valid.jsonl', valid_messages)]:
    (out/path).write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in records))
(out/'rehearsal.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest, indent=2))
