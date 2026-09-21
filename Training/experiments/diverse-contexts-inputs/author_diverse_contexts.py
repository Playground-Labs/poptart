"""Author a focused continuation set and prospective diagnostic; no model inference."""
import collections
import hashlib
import json
import runpy
import shutil
from pathlib import Path

prior = runpy.run_path('.context/author_diverse_objects.py')
corpus = prior['corpus']
make = prior['make']
normalize = prior['normalize']
spellings = prior['spellings']
ROOT = Path('Training/experiments/diverse-contexts-inputs')

training_terms = [
    'maple crate', 'brass kettle', 'canvas satchel', 'marble vase',
    'pine stool', 'clay planter', 'iron lantern', 'cotton hammock',
    'glass pitcher', 'cedar chest', 'leather cushion', 'silver mirror',
    'copper basin', 'stone tablet', 'paper screen', 'bamboo basket',
    'velvet curtain', 'tin bucket', 'oak cabinet', 'cork board',
    'silk drape', 'rubber mat', 'porcelain bowl', 'linen sheet',
    'bronze handle', 'felt cushion', 'steel cabinet', 'willow basket',
    'granite slab', 'reed curtain', 'wax tablet', 'wicker hamper',
]
diagnostic_terms = [
    'pewter tray', 'flannel coat', 'hemp basket', 'birch cabinet',
    'aluminum scoop', 'slate board', 'straw bonnet', 'ceramic urn',
]
physical_frames = [
    'The {phrase} rested on the workbench near the window',
    'I moved the {phrase} to the other side of the room',
    'Dust collected along the surface of the {phrase} overnight',
    'Please inspect the {phrase} before putting it back on the shelf',
]
application_frames = [
    'Please check the {phrase} application before closing the window',
    'Before leaving, I saved the document in the {phrase} application',
    'Our team opened the {phrase} program to review the draft',
    'The {phrase} software synchronized the latest changes',
]
diagnostic_physical_frames = [
    'The {phrase} stood beside the cabinet throughout the afternoon',
    'A worker cleaned the {phrase} after finishing the repair',
    'We wrapped the {phrase} before carrying it downstairs',
    'Please return the {phrase} to its usual place by the door',
]
diagnostic_application_frames = [
    'The {phrase} application imported the selected document',
    'I opened the {phrase} program before the morning meeting',
    'Our office uses {phrase} software for the weekly report',
    'Please install the {phrase} application on this computer',
]

seen = {normalize(term) for row in prior['records'] + prior['probe']
        for term in row.get('vocabularyTerms', [])}
for path in Path('Training/experiments').glob('*-inputs/diagnostic-*.jsonl'):
    for line in path.read_text().splitlines():
        if line.strip():
            seen.update(normalize(term) for term in json.loads(line).get('vocabularyTerms', []))
assert len(training_terms) == 32 and len(diagnostic_terms) == 8
assert len({normalize(term) for term in training_terms + diagnostic_terms}) == 40
assert not seen.intersection(normalize(term) for term in training_terms + diagnostic_terms)


def rows_for(terms, physical, applications, prefix, training):
    rows = []
    count = len(terms)
    for i, phrase in enumerate(terms):
        for style, target in enumerate(spellings(phrase)):
            for frame in range(4):
                distractor_style = i // (count // 4)
                distractor = spellings(terms[(i + count // 2) % count])[distractor_style]
                vocabulary = [target, distractor]
                mask = ((i % 8 + 2 * frame) % 8 if count == 32
                        else 4 * (i % 2) + 2 * (frame % 2) + frame // 2)
                if mask & 4:
                    vocabulary.reverse()
                for application in [False, True]:
                    template = applications[frame] if application else physical[frame]
                    row = make(
                        f'{prefix}-{i:02d}-{style}-{frame}-{int(application)}',
                        template.format(phrase=phrase), phrase, target, vocabulary,
                        application, training, lower=bool(mask & 2), omit_period=bool(mask & 1))
                    row['coverage'][0] = 'diverse-context-generalization'
                    rows.append(row)
    return rows


additions = rows_for(training_terms, physical_frames, application_frames,
                     'train-diverse-context', True)
probe = rows_for(diagnostic_terms, diagnostic_physical_frames,
                 diagnostic_application_frames, 'diverse-context-probe', False)
assert len(additions) == 1024 and len(probe) == 256

# Every style/frame/domain sees all distractor styles and all eight mechanics/order masks.
for rows, terms in [(additions, training_terms), (probe, diagnostic_terms)]:
    for style in range(4):
        for frame in range(4):
            for application in [0, 1]:
                group = [row for row in rows if row['id'].endswith(
                    f'-{style}-{frame}-{application}')]
                assert len(group) == len(terms)
                signatures = collections.Counter()
                distractor_styles = collections.Counter()
                for row in group:
                    i = int(row['id'].split('-')[3])
                    target = spellings(terms[i])[style]
                    signatures[(row['raw'][0].isupper(), row['raw'].endswith('.'),
                                row['vocabularyTerms'].index(target))] += 1
                    distractor_styles[i // (len(terms) // 4)] += 1
                expected_signatures = 8 if len(terms) == 32 else 2
                assert len(signatures) == expected_signatures
                assert set(signatures.values()) == {len(terms) // expected_signatures}
                assert set(distractor_styles) == set(range(4))
                styles_by_signature = collections.defaultdict(set)
                for row in group:
                    i = int(row['id'].split('-')[3])
                    target = spellings(terms[i])[style]
                    signature = (row['raw'][0].isupper(), row['raw'].endswith('.'),
                                 row['vocabularyTerms'].index(target))
                    styles_by_signature[signature].add(i // (len(terms) // 4))
                assert all(styles == set(range(4)) for styles in styles_by_signature.values())

# Keep old release and diagnostic text out of the new training partition.
evaluation_rows = [json.loads(line) for path in Path('Evals/fixtures').rglob('*.jsonl')
                   for line in path.read_text().splitlines() if line.strip()]
prior_diagnostics = {}
for path in Path('Training/experiments').glob('*-inputs/diagnostic-*.jsonl'):
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row['id'] in prior_diagnostics:
            assert prior_diagnostics[row['id']] == row
        prior_diagnostics[row['id']] = row
corpus.validate_partitions(additions, evaluation_rows + list(prior_diagnostics.values()) + probe)

seen_prompts = set()
train = [corpus.build(row, seen_prompts) for row in additions]
for row in probe:
    corpus.build(row, seen_prompts)
ROOT.mkdir(exist_ok=False)
(ROOT / 'corpus.jsonl').write_text(''.join(corpus.compact(row) + '\n' for row in additions))
(ROOT / 'train.jsonl').write_text(''.join(corpus.compact(row) + '\n' for row in train))
for split in ('valid', 'test'):
    shutil.copyfile(Path('Training/experiments/diverse-objects-inputs') / f'{split}.jsonl',
                    ROOT / f'{split}.jsonl')
for name, rows in [('added-training', additions), ('diagnostic-contexts', probe)]:
    (ROOT / f'{name}.jsonl').write_text(''.join(corpus.compact(row) + '\n' for row in rows))
(ROOT / 'added-training-gold.jsonl').write_text(''.join(
    corpus.compact(dict(row, expected=row['clean'])) + '\n' for row in additions))
(ROOT / 'author_diverse_contexts.py').write_text(Path(__file__).read_text())
(ROOT / 'coverage-audit.json').write_text(json.dumps(dict(
    trainingRecords=len(additions), prospectiveDiagnosticRecords=len(probe),
    trainingTerms=len(training_terms), diagnosticTerms=len(diagnostic_terms), styles=4,
    frames=4, domains=2, mechanicsOrderCombinations=8,
    focusedContinuation=True, priorTrainingExcludedFromThisContinuation=True,
    validSHA256=hashlib.sha256((ROOT / 'valid.jsonl').read_bytes()).hexdigest(),
    testSHA256=hashlib.sha256((ROOT / 'test.jsonl').read_bytes()).hexdigest(),
    allTargetsValidated=True, partitionGuardPassed=True,
    limitations=[
        'Authored synthetic contrasts cover eight prospective concepts, not 256 independent concepts.',
        'This focused continuation trains only on the 1,024 new records and relies on frozen validation plus regressions to detect forgetting.',
        'The prospective diagnostic was frozen before inference and is excluded from training and checkpoint selection.',
    ]), indent=2, sort_keys=True) + '\n')
print('Validated focused continuation', len(train), 'and prospective diagnostic', len(probe))
