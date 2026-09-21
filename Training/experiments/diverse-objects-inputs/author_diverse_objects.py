"""Author isolated train-only contrasts and a prospective diagnostic; no model inference."""
import collections
import hashlib
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path('Training').resolve()))
import prepare_corpus as corpus

ROOT = Path('Training/experiments/diverse-objects-inputs')
SOURCE = Path('Training/data/corpus.jsonl').read_bytes()
assert hashlib.sha256(SOURCE).hexdigest() == 'f38fb6adca3ebbb1028a7d2526eb9164107cafa93eb5ecb26f9bfc3265348f85'
old = [json.loads(line) for line in SOURCE.splitlines()]
# Every object has two independently authored physical descriptions. Application frames
# use the same phrase with an explicit application referent, not an arbitrary rewrite.
objects = [
 ('wooden spoon', 'stirred the thick soup without scratching the pot', 'The cook sanded a splinter off the {phrase}'),
 ('ceramic mug', 'chipped when it fell onto the kitchen tiles', 'Hot cocoa left a brown ring inside the {phrase}'),
 ('wool blanket', 'kept the sleeping child warm through the night', 'We folded the {phrase} at the foot of the bed'),
 ('leather glove', 'protected her palm from the rough rope', 'A cobbler stitched the torn thumb of the {phrase}'),
 ('bronze bell', 'rang when the clapper struck its inner wall', 'We lifted the heavy {phrase} onto the wooden stand'),
 ('cotton towel', 'absorbed the water spilled beside the sink', 'She hung the damp {phrase} over the shower rail'),
 ('iron nail', 'bent when the hammer struck it sideways', 'The carpenter pulled the {phrase} out of the board'),
 ('steel hinge', 'squeaked as the pantry door swung open', 'We tightened the screws on the {phrase} with a screwdriver'),
 ('rubber boot', 'kept the muddy water away from his sock', 'The child rinsed the mud from the sole of the {phrase}'),
 ('paper lantern', 'swayed beneath the string tied to the branch', 'A gust tore a hole in the side of the {phrase}'),
 ('stone mortar', 'held the peppercorns while the pestle crushed them', 'We rinsed ground spices out of the {phrase}'),
 ('bamboo flute', 'made a clear note when she blew across its opening', 'He covered the finger holes of the {phrase}'),
 ('linen napkin', 'caught the crumbs that fell from the bread', 'She tucked the {phrase} beneath the dinner plate'),
 ('glass marble', 'rolled across the floor and stopped under the chair', 'The child held the smooth {phrase} between two fingers'),
 ('clay jug', 'leaked through a crack near its rounded base', 'We poured fresh water from the {phrase} into a cup'),
 ('wire hanger', 'bent under the weight of the wet coat', 'He hooked the {phrase} over the closet rail'),
 ('wax candle', 'melted slowly as its small flame flickered', 'She trimmed the blackened wick of the {phrase}'),
 ('cork stopper', 'sealed the narrow opening of the bottle', 'We pulled the {phrase} free with a twisting motion'),
 ('tin whistle', 'made a shrill sound when the child blew into it', 'He wiped rainwater from the mouthpiece of the {phrase}'),
 ('velvet cushion', 'softened the hard seat of the wooden chair', 'She brushed loose lint from the {phrase}'),
 ('oak bench', 'supported three people beside the garden pond', 'We sanded a rough edge on the {phrase}'),
 ('reed mat', 'covered the cold stone floor near the doorway', 'She shook the dust out of the woven {phrase}'),
 ('silk scarf', 'fluttered from the coat hook in the breeze', 'He loosened the knot in the {phrase} around his neck'),
 ('rope ladder', 'hung from the treehouse above the grass', 'She gripped the wooden rungs of the {phrase}'),
 ('coal shovel', 'scooped black lumps into the furnace', 'We scraped soot from the blade of the {phrase}'),
 ('brass compass', 'pointed north while resting on the map', 'He polished the metal rim of the {phrase}'),
 ('porcelain plate', 'broke into three pieces on the stone floor', 'She arranged sliced pears on the {phrase}'),
 ('cedar plank', 'smelled fresh after the saw cut through it', 'The carpenter drilled two holes in the {phrase}'),
 ('felt hat', 'kept the drizzle off her forehead', 'He brushed dust from the brim of the {phrase}'),
 ('granite pebble', 'sank to the bottom of the shallow stream', 'We skipped the flat {phrase} across the pond'),
 ('copper pan', 'heated evenly over the gas flame', 'She scrubbed burnt sauce from the bottom of the {phrase}'),
 ('willow wreath', 'hung from a nail on the front door', 'We tucked dried flowers between the branches of the {phrase}'),
]
applications = [
 'Open the {phrase} application before editing the invoice',
 'The {phrase} application exports the selected photograph',
 'After the break, launch the {phrase} application to review the agenda',
 'We installed the {phrase} application on the office laptop',
 'Please update the {phrase} application before the next meeting',
 'She closed the {phrase} application after saving her draft',
 'Our team uses the {phrase} application to organize its appointments',
 'You can change the theme in the {phrase} application settings',
]
novel = [
 ('pewter goblet', 'held a small serving of grape juice', 'The silversmith repaired the bent stem of the {phrase}'),
 ('canvas awning', 'sheltered the doorway from the afternoon sun', 'Rainwater dripped from the edge of the {phrase}'),
 ('straw broom', 'swept dry leaves off the porch', 'She tied loose stalks back onto the {phrase}'),
 ('birch stool', 'stood beside the fireplace on three legs', 'We sanded the round seat of the {phrase}'),
 ('hemp cord', 'held the rolled blanket tightly together', 'He untied the knot at the end of the {phrase}'),
 ('slate tile', 'slid from the roof and cracked on the ground', 'She fitted the {phrase} beside the chimney'),
 ('aluminum funnel', 'guided the oil into the narrow bottle', 'We rinsed sticky syrup from the spout of the {phrase}'),
 ('flannel shirt', 'kept his arms warm in the chilly cabin', 'She sewed a button onto the cuff of the {phrase}'),
]

def normalize(term):
    return ''.join(term.lower().split())

def spellings(phrase):
    words = phrase.split()
    return [''.join(w.title() for w in words), phrase.title(), ''.join(words).upper(), ''.join(words)]

def make(identifier, sentence, phrase, target, terms, application, training, lower=False, omit_period=False):
    assert sentence.count(phrase) == 1 and not sentence.endswith('.')
    raw = sentence[0].lower() + sentence[1:] if lower else sentence
    raw += '' if omit_period else '.'
    spans = corpus.editplan.tokenize(raw)
    edits = []
    if lower:
        edits.append(dict(s=0, e=1, r=spans[0].text[0].upper() + spans[0].text[1:], c='capitalization'))
    if application:
        starts = [i for i in range(len(spans)-1) if [s.text for s in spans[i:i+2]] == phrase.split()]
        assert len(starts) == 1 and starts[0] > 0
        edits.append(dict(s=starts[0], e=starts[0]+2, r=target, c='vocabulary'))
    if omit_period:
        edits.append(dict(s=len(spans), e=len(spans), r='.', c='punctuation'))
    clean = (sentence.replace(phrase, target) if application else sentence) + '.'
    row = dict(id=identifier, provenance=corpus.PROVENANCE, raw=raw, clean=clean,
               vocabularyTerms=terms, editPlan=dict(v=1, e=edits),
               coverage=['diverse-object-contrast', 'application' if application else 'physical'])
    if training:
        row['split'] = 'train'
    else:
        row['expected'] = clean
    return row

prior_diagnostics = [json.loads(line) for p in Path('Training/experiments/canonical-copy-inputs').glob('diagnostic-*.jsonl')
                     for line in p.read_text().splitlines()]
seen_terms = {normalize(t) for r in old + prior_diagnostics for t in r.get('vocabularyTerms', [])}
assert len(objects) == 32 and len(novel) == 8
assert len({normalize(t) for t, _, _ in objects + novel}) == 40
assert not seen_terms.intersection(normalize(t) for t, _, _ in objects + novel)
additions = []
for i, (phrase, predicate, second) in enumerate(objects):
    for style, target in enumerate(spellings(phrase)):
        for frame in range(2):
            terms = [target, spellings(objects[(i+16)%32][0])[i//8]]
            mask = (i + frame) % 8
            if mask & 4:
                terms.reverse()
            for app in [False, True]:
                sentence = applications[(i%8 + 2*(i//8) + 2*frame)%8].format(phrase=phrase) if app else (
                    f'The {phrase} {predicate}' if frame == 0 else second.format(phrase=phrase))
                additions.append(make(f'train-diverse-object-{i:02d}-{style}-{frame}-{int(app)}', sentence,
                    phrase, target, terms, app, True, lower=bool(mask & 2), omit_period=bool(mask & 1)))
assert len(additions) == 512
# Check all eight mechanics/order combinations occur equally for every style/frame/domain.
for style in range(4):
    for frame in range(2):
        for app in [False, True]:
            group = [r for r in additions if r['id'].endswith(f'-{style}-{frame}-{int(app)}')]
            signatures = collections.Counter()
            for r in group:
                phrase = objects[int(r['id'].split('-')[3])][0]
                signatures[(r['raw'][0].isupper(), r['raw'].endswith('.'), r['vocabularyTerms'].index(spellings(phrase)[style]))] += 1
            assert len(signatures) == 8 and set(signatures.values()) == {4}
            for distractor_style in range(4):
                subgroup = [r for r in group if int(r['id'].split('-')[3])//8 == distractor_style]
                combinations = set()
                for r in subgroup:
                    i = int(r['id'].split('-')[3])
                    assert spellings(objects[(i+16)%32][0])[distractor_style] in r['vocabularyTerms']
                    combinations.add((r['raw'][0].isupper(), r['raw'].endswith('.'),
                                      r['vocabularyTerms'].index(spellings(objects[i][0])[style])))
                assert len(subgroup) == len(combinations) == 8
for style in range(4):
    for template in range(8):
        styles, mechanics = collections.Counter(), set()
        for row in additions:
            _, _, _, index, row_style, frame, application = row['id'].split('-')
            i, frame = int(index), int(frame)
            if int(row_style) == style and application == '1' and (i%8+2*(i//8)+2*frame)%8 == template:
                styles[i//8] += 1
                mechanics.add((row['raw'][0].isupper(), row['raw'].endswith('.'),
                               row['vocabularyTerms'].index(spellings(objects[i][0])[style])))
        assert len(styles) == 4 and set(styles.values()) == {2} and len(mechanics) == 8
probe = []
for i, (phrase, predicate, second) in enumerate(novel):
    for style, target in enumerate(spellings(phrase)):
        for frame in range(2):
            terms = [target, spellings(novel[(i+4)%8][0])[i//2]]
            if (i+frame)%2:
                terms.reverse()
            for app in [False, True]:
                sentence = ([f'The {phrase} application synchronizes our shared calendar',
                             f'Before leaving, I saved the document in the {phrase} application'][frame] if app else (
                             f'The {phrase} {predicate}' if frame == 0 else second.format(phrase=phrase)))
                probe.append(make(f'diverse-object-probe-{i:02d}-{style}-{frame}-{int(app)}', sentence,
                                  phrase, target, terms, app, False))
assert len(probe) == 128
for style in range(4):
    for frame in range(2):
        for app in [False, True]:
            pairs = collections.Counter()
            for r in probe:
                if r['id'].endswith(f'-{style}-{frame}-{int(app)}'):
                    i = int(r['id'].split('-')[3])
                    assert spellings(novel[(i+4)%8][0])[i//2] in r['vocabularyTerms']
                    pairs[(i//2, r['vocabularyTerms'].index(spellings(novel[i][0])[style]))] += 1
            assert len(pairs) == 8 and set(pairs.values()) == {1}
records = old + additions
# Frozen release contents are read only by the pre-existing leakage guard, never printed,
# used for authoring, or passed to model inference in this script.
evaluation_rows = [json.loads(line) for p in Path('Evals/fixtures').rglob('*.jsonl')
                   for line in p.read_text().splitlines() if line.strip()]
# The earlier physical training-fit diagnostic repeats eight original training rows.
# Verify those identities; they are not an additional held-out partition.
old_by_id = {r['id']: r for r in old}
held_diagnostics = []
for row in prior_diagnostics:
    if row['id'] in old_by_id:
        original = old_by_id[row['id']]
        assert original['split'] == 'train' and original['raw'] == row['raw']
        assert original['clean'] == row['expected'] and original['editPlan'] == row['editPlan']
    else:
        held_diagnostics.append(row)
corpus.validate_partitions(records, evaluation_rows + held_diagnostics + probe)
splits = {name: [] for name in ['train', 'valid', 'test']}
seen = set()
for row in records:
    splits[row['split']].append(corpus.build(row, seen))
for row in probe:
    corpus.build(row, seen)
ROOT.mkdir(exist_ok=True)
(ROOT/'corpus.jsonl').write_bytes(SOURCE + ''.join(corpus.compact(r)+'\n' for r in additions).encode())
for split, chats in splits.items():
    data = ''.join(corpus.compact(r)+'\n' for r in chats).encode()
    prior = Path('Training/experiments/canonical-copy-inputs')/(split+'.jsonl')
    if split == 'train':
        assert data.startswith(prior.read_bytes())
    else:
        assert data == prior.read_bytes()
    (ROOT/(split+'.jsonl')).write_bytes(data)
for name, rows in [('added-training', additions), ('diagnostic-diverse', probe)]:
    (ROOT/(name+'.jsonl')).write_text(''.join(corpus.compact(r)+'\n' for r in rows))
(ROOT/'added-training-gold.jsonl').write_text(''.join(corpus.compact(dict(r, expected=r['clean']))+'\n' for r in additions))
(ROOT/'author_diverse_objects.py').write_text(Path(__file__).read_text())
(ROOT/'coverage-audit.json').write_text(json.dumps(dict(newTrainingRecords=len(additions), prospectiveDiagnosticRecords=len(probe),
    trainingTerms=32, diagnosticTerms=8, styles=4, frames=2, domains=2, trainingMechanicsOrderCombinations=8,
    distractorStyles=4, distractorStyleIndependentOfTargetStyleOrderAndMechanics=True,
    preservedOriginalRecords=len(old), splits={k:len(v) for k,v in splits.items()},
    sourceCorpusSHA256=hashlib.sha256(SOURCE).hexdigest(), allTargetsValidated=True, partitionGuardPassed=True,
    limitations=['Authored synthetic contrasts;128diagnostic rows represent8terms, not128independent concepts.',
                'Application referents are explicit; broader natural-language vocabulary behavior still requires release/human evaluation.',
                'Prospective diagnostic frozen before inference; excluded from training and checkpoint selection.']), indent=2, sort_keys=True)+'\n')
print('Validated',len(records),'records;', {k:len(v) for k,v in splits.items()},'; prospective diagnostic',len(probe))
