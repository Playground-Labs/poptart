"""Prospective train-only preservation coverage; no runtime or heldout changes."""
import collections
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path('Training').resolve()))
import prepare_corpus as corpus

source = Path('Training/data/corpus.jsonl').read_bytes()
assert hashlib.sha256(source).hexdigest() == '2e9d87b7590a55d470727e1f04b5c7d02bfa82c08182104455f8f6a90c360663'
rows = [json.loads(line) for line in source.splitlines()]
objects = [
 ('blue envelope', ['is made of folded paper', 'contains a handwritten letter', 'has a stamp on its corner', 'is sealed with wax']),
 ('green basket', ['is woven from willow branches', 'contains three ripe peaches', 'has a broken wooden handle', 'is lined with a cotton cloth']),
 ('stone bridge', ['crosses a shallow stream', 'has moss growing between its blocks', 'casts a shadow on the river', 'has a cracked arch above the water']),
 ('red lantern', ['hangs from an iron hook', 'holds a flickering candle', 'has soot on its glass panels', 'casts a warm glow on the porch']),
 ('maple branch', ['has fresh leaves at its tip', 'rests against the garden fence', 'has bark peeling from its underside', 'is covered with melting snow']),
 ('silver ribbon', ['is tied around a birthday parcel', 'has a frayed edge near the knot', 'reflects sunlight from the window', 'lies across a folded piece of fabric']),
 ('copper kettle', ['contains boiling water', 'has a dent beside its spout', 'rests on the kitchen stove', 'has a wooden handle above its lid']),
 ('small harbor', ['shelters several fishing boats', 'has a stone wall along its entrance', 'is filled with seawater at high tide', 'lies below the fishing village']),
]
frames = ['The {} {}.', 'We noticed that the {} {}.', 'Please look at the {} that {}.', 'I can see that the {} {}.']
additions = []
def preserve(identifier, raw, terms, coverage):
    spans = corpus.editplan.tokenize(raw)
    edits = []
    if raw[0].islower():
        edits.append(dict(s=0,e=1,r=spans[0].text[0].upper()+spans[0].text[1:],c='capitalization'))
    if not raw.endswith('.'):
        edits.append(dict(s=len(spans),e=len(spans),r='.',c='punctuation'))
    clean = raw[0].upper()+raw[1:]
    if not clean.endswith('.'): clean += '.'
    additions.append(dict(id=identifier,provenance=corpus.PROVENANCE,split='train',raw=raw,clean=clean,
                          vocabularyTerms=terms,coverage=coverage,editPlan=dict(v=1,e=edits)))
for i,(phrase,clauses) in enumerate(objects):
    original = next(r for r in rows if r['id']==f'train-spelling-irrelevant-{i+1:03d}')
    for j,clause in enumerate(clauses):
        for k,frame in enumerate(frames):
            raw = frame.format(phrase,clause)
            # Cross capitalization and terminal punctuation with frame and object.
            if (i+j+k)%2: raw = raw[0].lower()+raw[1:] if not raw.startswith('I ') else raw
            if (i+j+ k//2)%2: raw = raw[:-1]
            terms = list(original['vocabularyTerms'])
            if (j//2+k//2)%2: terms.reverse()
            preserve(f'train-preservation-physical-{i:02d}-{j}-{k}',raw,terms,['physical-object','supplied-vocabulary-preservation'])
for i,(phrase,_) in enumerate(objects):
    group=[r for r in additions if r['id'].startswith(f'train-preservation-physical-{i:02d}-') and not r['raw'].startswith('I ')]
    target=next(r for r in rows if r['id']==f'train-spelling-irrelevant-{i+1:03d}')['vocabularyTerms']
    target=next(t for t in target if t.lower().replace(' ','')==phrase.replace(' ',''))
    assert len({(r['raw'][0].isupper(),r['vocabularyTerms'].index(target)) for r in group})==4
absent_frames = [
 'Please open the {} application for the costume workshop.',
 'we exported the rehearsal calendar through the {} application',
 'Our club uses the {} program to organize its equipment loans',
 'the new drawing is stored inside the {} application.'
]
positive_names = [next(e['r'] for e in next(r for r in rows if r['id']==f'train-position-{i:02d}-0')['editPlan']['e'] if e['c']=='vocabulary') for i in range(16)]
for i in range(16):
    original = next(r for r in rows if r['id']==f'train-position-{i:02d}-0')
    phrase = ' '.join(s.text for s in corpus.editplan.tokenize(original['raw'])[:2])
    for j,frame in enumerate(absent_frames):
        terms = [] if (i+j)%2==0 else [positive_names[(i+5)%16],positive_names[(i+9)%16]]
        if i%2: terms.reverse()
        preserve(f'train-preservation-unlisted-{i:02d}-{j}',frame.format(phrase),terms,['unlisted-name','empty-vocabulary' if not terms else 'unrelated-vocabulary'])
assert len(additions)==192
all_rows=rows+additions
seen=set()
for row in all_rows: corpus.build(row,seen)
evals=[json.loads(l) for p in Path('Evals/fixtures').rglob('*.jsonl') for l in p.read_text().splitlines() if l.strip()]
corpus.validate_partitions(all_rows,evals)
assert all(not any(e['c']=='vocabulary' for e in r['editPlan']['e']) for r in additions)
Path('.context/preservation-corpus-draft.jsonl').write_bytes(source+''.join(corpus.compact(r)+'\n' for r in additions).encode())
print('Validated',len(all_rows),'records;',collections.Counter(r['split'] for r in all_rows))
print('Added128physical32empty32unrelated; original768lines unchanged; builder and leakage guards pass.')
