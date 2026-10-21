"""Freeze matched source data and two target encodings; no evaluation text enters training."""
import json,sys,hashlib
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as p
import typed_operations as typed
root=Path(__file__).resolve().parent
out=Path('.context/cleanup-typed');out.mkdir(exist_ok=False)
load=lambda path:[json.loads(x) for x in Path(path).read_text().splitlines()]
train=load('Training/runs/2026-10-20-balanced-rehearsal/training.jsonl')
valid=load('Training/runs/2026-10-20-balanced-rehearsal/validation.jsonl')
clauses={
 'train':['and we fasten the canvas awning','then I rinse the empty flask','and we sort the brass fittings','then we carry the woven hamper','and I mend the torn curtain','then we lift the heavy planter','and we check the iron hinges','then I count the silver beads','and we gather the fallen branches','then we sweep the stone porch'],
 'valid':['and we dry the wooden paddles','then I inspect the copper kettle','and we fold the linen napkins','then we polish the marble shelf','and I replace the worn ribbon','then we unpack the clay ornaments']}
new=[]
for split,phrases in clauses.items():
 for i,raw in enumerate(phrases):
  n=len(p.editplan.tokenize(raw))
  for start in (False,True):
   edits=[]
   if start:edits.append({'s':0,'e':1,'r':raw.split()[0].capitalize(),'c':'capitalization'})
   edits.append({'s':n,'e':n,'r':'.','c':'punctuation'})
   row={'id':f'typed-context-{split}-{i:02}-{int(start)}','split':split,'raw':raw,'clean':(raw[0].upper()+raw[1:] if start else raw)+'.','editPlan':{'v':1,'e':edits},'provenance':p.PROVENANCE,'targetContext':dict(p.editplan.DEFAULT_TARGET_CONTEXT,textBeforeCursor='The earlier task is complete. ' if start else 'We handle the earlier task ')}
   new.append(row)
train += [r for r in new if r['split']=='train'];valid += [r for r in new if r['split']=='valid']
assert len(train)==100 and len(valid)==67
seen=set()
for row in train+valid:p.build(row,seen)
assert not {r['raw'] for r in train}&{r['raw'] for r in valid}
diagnostic=load('Training/runs/2026-10-20-span-context/fixtures.jsonl')
assert not {r['raw'] for r in train}&{r['raw'] for r in diagnostic}
evaluation=[dict(r,expected=r['clean'],group='existingValidation' if not r['id'].startswith('typed-context-') else 'newContext') for r in valid]+[dict(r,group='diagnostic-'+r['group']) for r in diagnostic]
assert len(evaluation)==91
for arm in ('range','typed'):
 (out/arm/'mlx').mkdir(parents=True)
 for split,rows in [('train',train),('valid',valid)]:
  messages=[]
  for row in rows:
   message=p.build(row,set())
   if arm=='typed':
    encoded=typed.encode(row['editPlan'],row['raw'])
    assert typed.compile_plan(encoded,row['raw'])==row['editPlan']
    message['messages'][0]['content']=typed.SYSTEM
    message['messages'][-1]['content']=json.dumps(encoded,separators=(',',':'),ensure_ascii=False)+p.editplan.STOP_MARKER
   messages.append(message)
  (out/arm/'mlx'/f'{split}.jsonl').write_text(''.join(json.dumps(m,ensure_ascii=False)+'\n' for m in messages))
for name,rows in [('training',train),('validation',valid),('evaluation',evaluation),('new-context',new)]:
 (root/(name+'.jsonl')).write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
protocol={'releaseQualified':False,'purpose':'Matched incremental feasibility comparison; starting adapter already favors range syntax. Not an equal from-scratch architecture comparison.','startingAdapter':'.context/cleanup-round8/adapters/0000200_adapters.safetensors','trainingRows':100,'validationLossRows':67,'evaluationRows':91,'steps':100,'learningRate':1e-5,'seed':20260824,'checkpointsEvaluated':[100],'arms':['retainedBaseline','range','typed'],'selection':'Typed must improve total exact over both retained baseline and matched range arm, preserve every correct output from either comparator, and improve at least one punctuation/filler/context diagnostic group. Otherwise reject and stop.','conditionalGate':'Only if selected: evaluate historical79+fresh16 with paired baseline, preserve all baseline-correct ordinary outputs and review changed/adversarial outputs. Native compiler/runtime parity required before any promotion.','stop':'One100-step run per trained arm; no prompt, budget or data revisions after results. No app or ADR changes.'}
(root/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
print('Prepared100 matched train,67 loss validation,91 evaluation;32 new context rows')
