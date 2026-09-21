"""Prospective novel-object probe, never a training or checkpoint selection input."""
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path('Training').resolve()))
import prepare_corpus as c
objects=[
 ('amber bottle','AmberBottle','The amber bottle contains a spoonful of olive oil.'),
 ('wooden chest','woodenchest','There are wool blankets inside the wooden chest.'),
 ('white canvas','White Canvas','The artist stretched the white canvas over a timber frame.'),
 ('glass bowl','GLASSBOWL','Please wash the glass bowl with warm soapy water.'),
 ('iron gate','IronGate','Our iron gate has rusty hinges beside the brick wall.'),
 ('paper crane','papercrane','We folded a paper crane from a square sheet.'),
 ('yellow bucket','Yellow Bucket','A yellow bucket caught the rain leaking through the roof.'),
 ('cotton bag','COTTONBAG','The cotton bag has a stitched handle and a torn lining.'),
]
second_negatives=[
 'We recycled the amber bottle after pouring out the oil.',
 'A brass key fits the lock on the wooden chest.',
 'The painter dabbed blue paint onto the white canvas.',
 'The glass bowl broke when it fell into the sink.',
 'The iron gate squeaks when its rusty hinges turn.',
 'A paper crane sits beside the other origami animals.',
 'The handle on the yellow bucket snapped under the weight of the sand.',
 'The cotton bag holds three apples and a loaf of bread.',
]
frames=['Our editor saved the draft in the {} application.',
        'Please export the schedule from the {} program.']
records=[]
for i,(phrase,term,negative) in enumerate(objects):
    for j in range(2):
        terms=[term,'Moss Ledger'] if (i//4+j)%2 else ['Moss Ledger',term]
        for kind,raw in [('physical',[negative,second_negatives[i]][j]),('application',frames[j].format(phrase))]:
            edits=[]
            if kind=='application':
                spans=c.editplan.tokenize(raw)
                words=phrase.split()
                starts=[n for n in range(len(spans)-1) if [s.text for s in spans[n:n+2]]==words]
                assert len(starts)==1
                edits=[dict(s=starts[0],e=starts[0]+2,r=term,c='vocabulary')]
            clean=raw if kind=='physical' else raw.replace(phrase,term)
            record=dict(id=f'preservation-probe-{i:02d}-{j}-{kind}',provenance=c.PROVENANCE,raw=raw,
                        clean=clean,expected=clean,vocabularyTerms=terms,editPlan=dict(v=1,e=edits),
                        coverage=['prospective-novel-term',kind])
            c.build(record,set())
            records.append(record)
for style in range(4):
    group=[r for r in records if int(r['id'].split('-')[2])%4==style and r['coverage'][-1]=='application']
    assert {(r['editPlan']['e'][0]['s'],r['vocabularyTerms'].index(r['editPlan']['e'][0]['r'])) for r in group}=={(6,0),(6,1),(7,0),(7,1)}
train=[json.loads(l) for l in Path('.context/preservation-corpus-draft.jsonl').read_text().splitlines()]
c.validate_partitions(train,records)
assert all(term not in r.get('vocabularyTerms',[]) for _,term,_ in objects for r in train)
Path('.context/preservation-probe.jsonl').write_text(''.join(c.compact(r)+'\n' for r in records))
print('Validated32novel-term probes; no corpus overlap; not used for selection.')
