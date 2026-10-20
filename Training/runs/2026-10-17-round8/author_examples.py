"""Author synthetic examples; validates every explicit clean target before writing."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as p

root=Path('Training/runs/2026-10-17-round8')
def e(s,t,r,c): return dict(s=s,e=t,r=r,c=c)
def punct(raw,mark='.'): return e(len(p.editplan.tokenize(raw)),len(p.editplan.tokenize(raw)),mark,'punctuation')
def cap(raw):
    first=p.editplan.tokenize(raw)[0].text
    return [] if first==first[0].upper()+first[1:] else [e(0,1,first[0].upper()+first[1:],'capitalization')]
def record(identifier,split,raw,clean,edits,**extra):
    return dict(id=identifier,split=split,provenance=p.PROVENANCE,raw=raw,clean=clean,editPlan={'v':1,'e':edits},**extra)
# Last two topics are validation-only; all variants of a topic share its split.
clauses=[
 'we agree', 'the exhibit closes at dusk', 'I counted 48 tickets',
 'our technician replaced the cracked ceramic handle yesterday',
 'the ferry crew secured every loose crate before the approaching storm reached the harbor',
 'she kept the original receipt inside a waterproof pouch',
 'we will display the miniature railway beside the entrance',
 'the repair needs two washers and a longer bolt',
 'I placed each numbered card in a separate envelope',
 'they found the missing pendant behind the dresser',
 'the geologist recorded the temperature near the crater',
 'we reserved the smallest cabin overlooking the valley',
]
rows=[]
for i,raw in enumerate(clauses):
    split='train' if i<10 else 'valid'
    clean=raw[0].upper()+raw[1:]+'.'
    variants=[]
    variants.append(('statement',raw,clean,cap(raw)+[punct(raw)],{}))
    upper=raw[0].upper()+raw[1:]
    variants.append(('capital',upper,clean,[punct(upper)],{}))
    for filler in ['um','uh']:
        leading=filler+' '+raw
        edits=[e(0,1,'','filler')]+[e(x['s']+1,x['e']+1,x['r'],x['c']) for x in cap(raw)]+[punct(leading)]
        variants.append(('leading_'+filler,leading,clean,edits,{}))
    trailing=raw+' um'
    n=len(p.editplan.tokenize(trailing))
    variants.append(('trailing',trailing,clean,cap(raw)+[e(n-1,n,'','filler'),punct(trailing)],{}))
    words=raw.split(); index=min(3,len(words)-1)
    repeat=' '.join(words[:index+1]+words[index:])
    variants.append(('repetition',repeat,clean,cap(raw)+[e(index+1,index+2,'','repetition'),punct(repeat)],{}))
    variants.append(('continuation',raw,raw+'.',[punct(raw)],{'targetContext':{**p.editplan.DEFAULT_TARGET_CONTEXT,'textBeforeCursor':'We confirmed that '}}))
    variants.append(('new_sentence',raw,clean,cap(raw)+[punct(raw)],{'targetContext':{**p.editplan.DEFAULT_TARGET_CONTEXT,'textBeforeCursor':'The inspection is complete. '}}))
    for kind,text,target,edits,extra in variants:
        rows.append(record(f'round8-{kind}-{i+1:03}',split,text,target,edits,**extra))
vocabulary=[
 ('ask the birch haven team to confirm the appointment','birch haven','Birchhaven'),
 ('please attach the red meadow invoice to the expense report','red meadow','Redmeadow'),
 ('we should archive the files from copper vale before Friday','copper vale','Coppervale'),
 ('I downloaded the frost ridge manual to the workshop computer','frost ridge','Frostridge'),
 ('after the meeting send the stone willow summary to the entire committee','stone willow','Stonewillow'),
 ('check whether the moss point delivery arrived at the warehouse this morning','moss point','Mosspoint'),
 ('the technician will inspect the hazel forge device after lunch','hazel forge','Hazelforge'),
 ('please ask the night grove coordinator about the revised opening hours','night grove','Nightgrove'),
 ('we kept the ash hollow receipts in the locked filing cabinet','ash hollow','Ashhollow'),
 ('I need another copy of the cloud fen installation instructions today','cloud fen','Cloudfen'),
 ('send the mint hollow proposal to the review committee tomorrow','mint hollow','Minthollow'),
 ('we can discuss the bright mere contract after the weekly staff briefing','bright mere','Brightmere'),
]
for i,(raw,spoken,term) in enumerate(vocabulary):
    tokens=[t.text for t in p.editplan.tokenize(raw)]; start=tokens.index(spoken.split()[0])
    clean=raw.replace(spoken,term);clean=clean[0].upper()+clean[1:]+'.'
    rows.append(record(f'round8-vocabulary-{i+1:03}','train' if i<10 else 'valid',raw,clean,cap(raw)+[e(start,start+2,term,'vocabulary'),punct(raw)],vocabularyTerms=[term]))
# Independently authored evaluation sentences, never generated from the clauses above.
cases=[
 ('I fastened the kayak to the roof rack','I fastened the kayak to the roof rack.',[punct('I fastened the kayak to the roof rack')],{}),
 ('send it uh','Send it.',[e(0,1,'Send','capitalization'),e(2,3,'','filler'),punct('send it uh')],{}),
 ('the gardener planted six rows of lavender along the southern fence um','The gardener planted six rows of lavender along the southern fence.',None,{}),
 ('uh I finished labeling the specimen jars','I finished labeling the specimen jars.',[e(0,1,'','filler'),punct('uh I finished labeling the specimen jars')],{}),
 ('um take the spare helmet to the loading dock','Take the spare helmet to the loading dock.',[e(0,1,'','filler'),e(1,2,'Take','capitalization'),punct('um take the spare helmet to the loading dock')],{}),
 ('we need the green green ribbon for the award ceremony','We need the green ribbon for the award ceremony.',[e(0,1,'We','capitalization'),e(4,5,'','repetition'),punct('we need the green green ribbon for the award ceremony')],{}),
 ('I moved the small small amplifier into the rehearsal booth','I moved the small amplifier into the rehearsal booth.',[e(4,5,'','repetition'),punct('I moved the small small amplifier into the rehearsal booth')],{}),
 ('they have enough fuel for the return journey','they have enough fuel for the return journey.',[punct('they have enough fuel for the return journey')],{'targetContext':{**p.editplan.DEFAULT_TARGET_CONTEXT,'textBeforeCursor':'The pilot assured us that '}}),
 ('we can reopen the trail once the fallen branches are removed','We can reopen the trail once the fallen branches are removed.',None,{'targetContext':{**p.editplan.DEFAULT_TARGET_CONTEXT,'textBeforeCursor':'The bridge has been repaired. '}}),
 ('and the spare keys are inside the drawer','and the spare keys are inside the drawer.',[punct('and the spare keys are inside the drawer')],{'targetContext':{**p.editplan.DEFAULT_TARGET_CONTEXT,'textBeforeCursor':'The main key is on the hook '}}),
 ('please forward the dune crest estimate to the purchasing office by noon','Please forward the Dunecrest estimate to the purchasing office by noon.',[e(0,1,'Please','capitalization'),e(3,5,'Dunecrest','vocabulary'),punct('please forward the dune crest estimate to the purchasing office by noon')],{'vocabularyTerms':['Dunecrest','Crestline']}),
 ('I saved the latest wave glen drawings beside the signed inspection forms','I saved the latest Waveglen drawings beside the signed inspection forms.',[e(4,6,'Waveglen','vocabulary'),punct('I saved the latest wave glen drawings beside the signed inspection forms')],{'vocabularyTerms':['Waveglen']}),
 ('The abbreviation um belongs in this quoted sentence.','The abbreviation um belongs in this quoted sentence.',[],{}),
 ('Keep the reference ID QR-902 exactly as written.','Keep the reference ID QR-902 exactly as written.',[],{}),
 ('when will the replacement microscope arrive','When will the replacement microscope arrive?',[e(0,1,'When','capitalization'),punct('when will the replacement microscope arrive','?')],{}),
 ('The spare battery is fully charged.','The spare battery is fully charged.',[],{}),
]
held=[]
for i,(raw,clean,edits,extra) in enumerate(cases,1):
    if edits is None:
        edits=cap(raw)
        if raw.endswith(' um'):
            n=len(p.editplan.tokenize(raw)); edits+=[e(n-1,n,'','filler')]
        edits+=[punct(raw)]
    held.append(record(f'round8-independent-{i:03}','test',raw,clean,edits,**extra))
seen=set()
for r in rows+held:p.build(r,seen)
existing=[r for r in map(json.loads,p.SOURCE.read_text().splitlines()) if not r['id'].startswith('round8-')]
normalize=lambda r:' '.join(p.editplan.word_list(r['raw']))
train={normalize(r) for r in existing+rows if r['split']=='train'}
valid={normalize(r) for r in existing+rows if r['split']!='train'}
assert not train&valid
old=[]
for file in Path('Training/data').glob('*.jsonl'):old += [json.loads(line) for line in file.read_text().splitlines()]
old += [json.loads(line) for line in Path('Training/runs/2026-10-17-round6/unseen.jsonl').read_text().splitlines()]
assert not {normalize(r) for r in rows+held}&{normalize(r) for r in old if not r['id'].startswith('round8-')}
assert len({normalize(r) for r in held})==len(held)
assert not {normalize(r) for r in held}&(train|valid)
for name,data in [('new-examples.jsonl',rows),('independent.jsonl',held)]:
    with (root/name).open('x') as f:
        for r in data:f.write(json.dumps(r)+'\n')
print('Validated',len(rows),'new train/validation examples and',len(held),'independent cases')
