"""Freeze paired trailing-filler examples and a deterministic rehearsal sample."""
import json,random,sys,hashlib
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as p
root=Path('Training/runs/2026-10-20-targeted-filler')
def load(path):return [json.loads(x) for x in Path(path).read_text().splitlines()]
def write(name,rows):
 with (root/name).open('x') as f:
  for r in rows:f.write(json.dumps(r,ensure_ascii=False)+'\n')
train='''close the attic hatch
we found a bronze whistle
I folded the striped blanket carefully
put the lentils beside the stove
the locksmith returned before sunrise
our neighbors adopted two elderly rabbits
please unplug the mixer after lunch
the brass compass belongs to my uncle
I left a folded map underneath the cushion
her assistant measured the narrow window twice
move those clay pots into the conservatory
the librarian repaired several torn pages yesterday
we should refrigerate the remaining soup tonight
pack the wool socks in the outer pocket
I watched a small beetle cross the path
our sculptor chose a pale piece of marble
check the pressure before opening the valve
the wooden gate creaks whenever the wind changes
bring the sealed jar down from the shelf
I will label every drawer after the delivery arrives
we need a longer ladder to reach the damaged gutter
please leave enough room for the folding chairs beside the counter
the photographer placed a silver reflector near the open doorway
my cousin mailed the handwritten recipe to our aunt last Friday'''.splitlines()
valid=['the beekeeper inspected each frame before replacing the lid','I stored the spare hinges in a biscuit tin','please rinse the measuring jug with warm water','we spotted a heron beside the flooded meadow']
test=['the astronomer covered the telescope before dawn','I can mend the torn sail this afternoon','leave the carved chess pieces on the mantelpiece','our potter wrapped each bowl in recycled paper','we counted six otters near the estuary','please tighten the rear wheel before the next journey','the archivist placed the brittle letters inside protective sleeves','I brought a small torch for the walk through the tunnel']
def e(s,t,r,c):return dict(s=s,e=t,r=r,c=c)
new=[]
for split,clauses in [('train',train),('valid',valid),('test',test)]:
 for i,clause in enumerate(clauses):
  for variant in ('plain','filler'):
   raw=clause+(' '+('um' if i%2==0 else 'uh') if variant=='filler' else '')
   spans=p.editplan.tokenize(raw);first=spans[0].text;edits=[]
   if first!=first.capitalize():edits.append(e(0,1,first.capitalize(),'capitalization'))
   if variant=='filler':edits.append(e(len(spans)-1,len(spans),'','filler'))
   edits.append(e(len(spans),len(spans),'.','punctuation'))
   new.append(dict(id=f'targeted-{split}-{i:02}-{variant}',split=split,provenance=p.PROVENANCE,raw=raw,clean=clause[0].upper()+clause[1:]+'.',editPlan={'v':1,'e':edits}))
corpus=load('Training/data/corpus.jsonl');seen=set()
for r in corpus+new:p.build(r,seen)
# No new sentence may duplicate any historical raw input or expected output.
historical=set()
for path in [*Path('Training/data').glob('*.jsonl'),*Path('Evals/fixtures').glob('*.jsonl'),Path('Training/runs/2026-10-17-round6/unseen.jsonl')]:
 for r in load(path):
  for key in ('raw','clean','expected'):
   if isinstance(r.get(key),str):historical.add(' '.join(p.editplan.word_list(r[key])))
assert all(' '.join(p.editplan.word_list(r['raw'])) not in historical for r in new)
# Clause pairs never cross splits.
assert len(set(train+valid+test))==len(train+valid+test)
rehearsal=random.Random(20261020).sample([r for r in corpus if r['split']=='train'],32)
training=rehearsal+[r for r in new if r['split']=='train']
validation=[r for r in corpus if r['split']=='valid']+[r for r in new if r['split']=='valid']
assert len(training)==80 and len(validation)==55
write('new-examples.jsonl',new);write('training.jsonl',training);write('validation.jsonl',validation);write('fresh-evaluation.jsonl',[r for r in new if r['split']=='test'])
(root/'mlx').mkdir()
for name,rows in [('train',training),('valid',validation)]:write(f'mlx/{name}.jsonl',[p.build(r,set()) for r in rows])
print('Validated 72 new synthetic examples; 80 train / 55 validation / 16 fresh evaluation.')
