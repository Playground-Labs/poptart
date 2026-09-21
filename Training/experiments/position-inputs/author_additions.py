"""Prospective authored vocabulary-position training additions; no evaluation cases copied."""
import collections
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path('Evals').resolve()))
import editplan
import run as evaluation

names = [('rain bow', 'Rainbow'), ('key board', 'KeyBoard'),
    ('book shelf', 'bookshelf'), ('sun rise', 'Sun Rise'),
    ('tea pot', 'TeaPot'), ('foot note', 'Footnote'),
    ('blue print', 'blueprint'), ('work bench', 'Work Bench'),
    ('cloud kite', 'Cloudkite'), ('pine orbit', 'PineOrbit'),
    ('moss lantern', 'mosslantern'), ('amber sail', 'Amber Sail'),
    ('reed canvas', 'Reedcanvas'), ('fern compass', 'FernCompass'),
    ('stone chorus', 'stonechorus'), ('willow loom', 'Willow Loom')]
templates = [
    ('{} is the application for our shared notes.', '{} is the program that exports our rehearsal schedule.'),
    ('Launch {} to access the online workspace.', 'Use {} to open the project database.'),
    ('Please launch {} on this computer.', 'We use {} as our diagramming application.'),
    ('The team uses {} as its scheduling application.', 'Our volunteers prefer {} as their scheduling software.'),
    ('Our small team uses {} as its scheduling application.', 'The studio team chose {} as its design application.'),
    ('Keep the drawing in the {} application until Friday.', 'The shared archive uses the {} application for automatic backups.'),
    ('Put the workshop roster inside the {} application before leaving.', 'For the current project we use {} as the scheduling application.'),
    ('We keep the workshop roster in the {} application.', 'The committee stores its minutes in the {} application.')]
preservation_templates = ['The {} application contains the rehearsal notes.',
    'Our coordinator saved another copy in the {} application.',
    'The latest export from the {} application includes every attachment.',
    'A separate folder in the {} application contains the revised diagrams.']
rows = []
for name_index, (source, term) in enumerate(names):
    for position, alternatives in enumerate(templates):
        template = alternatives[(name_index // 4 + position) % 2]
        raw = template.format(source)
        spans = editplan.tokenize(raw)
        start = next(span.index for span in spans if span.text == source.split()[0])
        assert start == position
        terms = [term, names[(name_index + 5) % len(names)][1]]
        if (name_index + position) % 2:
            terms.reverse()
        rows.append(dict(id=f'train-position-{name_index:02d}-{position}',
            provenance=dict(kind='authoredSynthetic', author='Playground Labs', license='CC0-1.0', source='repository'),
            split='train', raw=raw, clean=template.format(term), vocabularyTerms=terms,
            editPlan=dict(v=1, e=[dict(s=start, e=start + 2, r=term, c='vocabulary')])))
    # A supplied name that already has its intended spelling needs no model edit.
    raw = preservation_templates[name_index % len(preservation_templates)].format(term)
    terms = [term, names[(name_index + 5) % len(names)][1]]
    if (name_index // 4 + name_index) % 2:
        terms.reverse()
    rows.append(dict(id=f'train-position-preserve-{name_index:02d}',
        provenance=dict(kind='authoredSynthetic', author='Playground Labs', license='CC0-1.0', source='repository'),
        split='train', raw=raw, clean=raw, vocabularyTerms=terms, editPlan=dict(v=1, e=[])))
assert len(rows) == 144 and len({r['id'] for r in rows}) == 144
for row in rows:
    evaluation.validate_gold({**row, 'expected': row['clean']})
histogram = collections.Counter(e['s'] for row in rows for e in row['editPlan']['e'])
assert histogram == {i: 16 for i in range(8)}
output = Path('.context/position-additions.jsonl')
with output.open('w') as stream:
    for row in rows:
        stream.write(json.dumps(row, ensure_ascii=False) + '\n')
print('Validated144 proposed records:128 vocabulary edits at starts0..7,16 perstart;16 no-ops.')
