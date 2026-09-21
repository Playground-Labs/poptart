"""Train-only vocabulary spelling contrasts plus a prospective unseen-term diagnostic."""
import collections,hashlib,json,sys
from pathlib import Path
sys.path.insert(0,str(Path('Training').resolve()))
import prepare_corpus as corpus
source=Path('Training/data/corpus.jsonl').read_bytes()
assert hashlib.sha256(source).hexdigest()=='5e16e80c0d879a29fd421816563b06bcd7fe5086ffaaedca585376f7bfe9d23b'
rows=[json.loads(l) for l in source.splitlines()]
objects=[
 ('blue envelope','contains a folded paper invitation','has a handwritten address on its flap'),
 ('green basket','has a split willow handle','holds several freshly picked plums'),
 ('stone bridge','has a weathered arch above the creek','supports the footpath across the stream'),
 ('red lantern','has candle wax beneath its wick','casts a flickering light on the stone wall'),
 ('maple branch','has a bird nest between its twigs','scrapes the roof when the wind blows'),
 ('silver ribbon','has a silk knot around the package','shines in the light from the window'),
 ('copper kettle','has steam coming from its spout','contains hot water for the tea'),
 ('small harbor','shelters two wooden fishing boats','fills with seawater as the tide rises'),
]
def spellings(phrase):
 words=phrase.split()
 return [''.join(w.title() for w in words),' '.join(w.title() for w in words),''.join(words).upper(),''.join(words)]
def make(identifier,raw,phrase,target,terms,application,training):
 spans=corpus.editplan.tokenize(raw);edits=[]
 if raw[0].islower():edits.append(dict(s=0,e=1,r=spans[0].text[0].upper()+spans[0].text[1:],c='capitalization'))
 if application:
  words=phrase.split();start=next(i for i in range(len(spans)-1) if [s.text for s in spans[i:i+2]]==words)
  edits.append(dict(s=start,e=start+2,r=target,c='vocabulary'))
 if not raw.endswith('.'):edits.append(dict(s=len(spans),e=len(spans),r='.',c='punctuation'))
 clean=raw[0].upper()+raw[1:]
 if application:clean=clean.replace(phrase,target)
 if not clean.endswith('.'):clean+='.'
 record=dict(id=identifier,provenance=corpus.PROVENANCE,raw=raw,vocabularyTerms=terms,editPlan=dict(v=1,e=edits))
 if training:record.update(split='train',clean=clean,coverage=['canonical-spelling-contrast','application-name' if application else 'physical-object-preservation'])
 else:record.update(clean=clean,expected=clean,coverage=['prospective-canonical-spelling','application' if application else 'physical'])
 return record
additions=[]
for i,(phrase,first,second) in enumerate(objects):
 old=next(r for r in rows if r['id']==f'train-spelling-irrelevant-{i+1:03d}')
 distractor=next(t for t in old['vocabularyTerms'] if ''.join(t.lower().split())!=phrase.replace(' ',''))
 for style,target in enumerate(spellings(phrase)):
  for frame in range(2):
   terms=[target,distractor]
   if (i+frame)%2:terms.reverse()
   for app in [False,True]:
    raw=([f'The {phrase} {first}.',f'we noticed that the {phrase} {second}'] if not app else
         [f'The {phrase} application keeps the inventory available.',f'we noticed that the {phrase} application saved the rehearsal notes'])[frame]
    raw=raw[0].upper()+raw[1:]
    if i & 2:raw=raw[0].lower()+raw[1:]
    if i & 4:raw=raw.rstrip('.')
    elif not raw.endswith('.'):raw+='.'
    additions.append(make(f'train-canonical-copy-{i:02d}-{style}-{frame}-{int(app)}',raw,phrase,target,terms,app,True))
assert len(additions)==128
for style in range(4):
 for frame in range(2):
  for app in [False,True]:
   group=[r for r in additions if r['id'].endswith(f'-{style}-{frame}-{int(app)}')]
   signatures=set()
   for r in group:
    term=objects[int(r['id'].split('-')[3])][0]
    target=spellings(term)[style]
    signatures.add((r['raw'][0].isupper(),r['raw'].endswith('.'),r['vocabularyTerms'].index(target)))
   assert len(signatures)==8,(style,frame,app,signatures)
allrows=rows+additions;seen=set()
for row in allrows:corpus.build(row,seen)
# Reading only to enforce the existing leakage guard; no held-out text is emitted or used for authoring.
evals=[json.loads(l) for p in Path('Evals/fixtures').rglob('*.jsonl') for l in p.read_text().splitlines() if l.strip()]
corpus.validate_partitions(allrows,evals)
Path('.context/canonical-copy-corpus-draft.jsonl').write_bytes(source+''.join(corpus.compact(r)+'\n' for r in additions).encode())
probe=[]
novel_objects=[
 ('amber spool','has thread wound around its wooden core'),('linen pouch','has a drawstring sewn into its hem'),
 ('cedar shelf','holds a row of ceramic bowls'),('brass tray','has a dent beside its curved handle')]
for i,(phrase,physical) in enumerate(novel_objects):
 # Diagnostic terms are not copied from the corpus and never used for training or checkpoint selection.
 assert all(phrase.replace(' ','') not in ''.join(t.lower().split()) for row in rows for t in row.get('vocabularyTerms',[]))
 for style,target in enumerate(spellings(phrase)):
  for frame in range(2):
   terms=[target,spellings(novel_objects[(i+1)%4][0])[(style+frame+i)%4]]
   if (i+frame)%2:terms.reverse()
   for app in [False,True]:
    raw=([f'The {phrase} {physical}.',f'Please check the {phrase} that {physical}.'] if not app else
         [f'The {phrase} application stores the revised itinerary.',f'Please check the {phrase} application for the revised itinerary.'])[frame]
    probe.append(make(f'canonical-probe-{i}-{style}-{frame}-{int(app)}',raw,phrase,target,terms,app,False))
corpus.validate_partitions(allrows,evals+probe)
for row in probe:corpus.build(dict(row,clean=row['expected']),set())
Path('.context/canonical-copy-probe-draft.jsonl').write_text(''.join(corpus.compact(r)+'\n' for r in probe))
print('validated',len(allrows),collections.Counter(r['split'] for r in allrows),'newtrain',len(additions),'prospectiveprobe',len(probe))
