"""Authored training-only coverage of variable punctuation positions and literal casing."""
import json,sys
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as corpus
import editplan
clauses='''Snow melts|the creek rises
Rain falls|our boots stay inside
Doors close|the audience grows quiet
Plants grow|their roots need space
The kettle whistles|breakfast is nearly ready
My phone rang|the caller left no message
Our guests arrived|we offered them cold water
Her train departed|she waved through the window
The last bus leaves soon|we should reach the stop
Our youngest cousin plays violin|her brother prefers the flute
This brass key opens nothing|the matching lock was replaced
A small bird landed nearby|its feathers looked wet
The grey cat watches passing bicycles|the dog sleeps beside her
Our old kitchen clock stopped ticking|its battery needs replacing
The large front window needs cleaning|the ladder is in the shed
My spare hiking boots are drying|the insoles are still damp
The narrow lane behind our house floods|the main road stays clear
A bright red kite crossed the field|its string caught on a fence
Our local bakery sells fresh bread daily|the shelves empty by noon
The wooden crate under that bench rattles|a loose hinge needs tightening
The youngest member of our quartet plays cello|her solo opens the recital
A fresh coat of paint covers the railing|the stairs are still unfinished
My aunt planted three cherry trees last spring|their branches now reach the fence
The final parcel from our supplier arrived yesterday|its contents match the order'''
symbols='''add ⭐ beside the option you prefer
send 👍 if the arrangement works for you
please put 📦 next to the collection time
our invitation needs 🎉 near the heading
keep the 🧭 icon above the navigation menu
place a 🪴 symbol beside the indoor planting advice
use the 🔑 marker for entries requiring a key
the route marked 🚲 follows the riverbank
leave the family symbol 👪 on the welcome sign
put ☀️ next to the sunny weather prediction
that label uses 🌈 beside the club name
we added 🔧 to the maintenance rota
please keep the hand symbol ✌️ on the poster
the sample with 👩🏽 belongs in the staff directory
our return instructions show ↩️ beside the address
we use ♻️ for the reusable packaging option'''
capitalized='''I left a spare towel on the lower shelf
I can collect the repair kit on Wednesday
I already checked the latch beside the handle
I would prefer the smaller bowl for serving
I found another copy behind the cupboard
I will wait near the western entrance
I still need a clean brush for the varnish
I put the dried herbs in separate jars
Maya borrowed the blue umbrella yesterday
Oliver keeps his bicycle near the garden gate
Nora booked the rehearsal room for Thursday
Felix returned the empty basket after supper
Rosa teaches the afternoon ceramics class
Jasper found a loose button beneath the chair
Clara will bring the measuring tape tomorrow
Ethan left the folded blanket on the bench'''
lists='''We bought pears, plums and peaches
They brought pens, rulers and notebooks
Please pack socks, gloves and scarves
Our basket contains warm bread, cheese and sliced tomatoes
The top drawer holds small brushes, pencils and spare nibs
Her parcel contained a folded scarf, two mittens and a hat
This cupboard stores clean cups, saucers and dinner plates
The available colours are deep blue, pale green and cream'''
rows=[]
def add(group,index,raw,clean,edits):
    row=dict(id=f'train-boundary-{group}-{index+1:03}',split='train',provenance=corpus.PROVENANCE,
             raw=raw,clean=clean,editPlan=dict(v=1,e=sorted(edits,key=lambda e:(e['s'],e['e']))),coverage=[group,'literal-casing-and-boundaries'])
    corpus.build(row,set());rows.append(row)
def edit(s,e,r,c):return dict(s=s,e=e,r=r,c=c)
def mechanics(raw):
    spans=editplan.tokenize(raw);edits=[]
    if spans[0].text[0].islower():edits.append(edit(0,1,spans[0].text[0].upper()+spans[0].text[1:],'capitalization'))
    if spans[-1].text!='.':edits.append(edit(len(spans),len(spans),'.','punctuation'))
    return spans,edits
for i,line in enumerate(clauses.splitlines()):
    first,second=line.split('|')
    raw=(first[0].lower()+first[1:] if i%2 else first)+', '+second+('.' if (i//2)%2 else '')
    spans,edits=mechanics(raw);comma=next(j for j,s in enumerate(spans) if s.text==',')
    edits.extend([edit(comma,comma+1,'.','punctuation'),edit(comma+1,comma+2,spans[comma+1].text.capitalize(),'capitalization')])
    add('independent-clauses',i,raw,first+'. '+second[0].upper()+second[1:]+'.',edits)
for group,block in [('inline-symbol',symbols),('coordinated-list',lists)]:
    for i,text in enumerate(block.splitlines()):
        raw=(text[0].lower()+text[1:] if i%2 else text[0].upper()+text[1:])+('.' if (i//2)%2 else '')
        spans,edits=mechanics(raw)
        add(group,i,raw,text[0].upper()+text[1:]+'.',edits)
for i,text in enumerate(capitalized.splitlines()):
    filler=['um','uh','erm','er'][i%4]
    raw=(filler.capitalize() if (i//4)%2 else filler)+' '+text+('.' if ((i//8)+(i//4)+(i%2))%2 else '')
    spans=editplan.tokenize(raw);edits=[edit(0,1,'','filler')]
    if spans[-1].text!='.':edits.append(edit(len(spans),len(spans),'.','punctuation'))
    add('filler-before-capital',i,raw,text+'.',edits)
assert len(rows)==64
for filler in ['um','uh','erm','er']:
    cases=[r for r in rows if r['raw'].split()[0].lower()==filler]
    assert {(r['raw'][0].isupper(),r['raw'].endswith('.')) for r in cases}=={(a,b) for a in [False,True] for b in [False,True]}
    assert {(r['raw'].split()[1]=='I',r['raw'].endswith('.')) for r in cases}=={(a,b) for a in [False,True] for b in [False,True]}
existing=[json.loads(l) for l in Path('Training/data/corpus.jsonl').read_text().splitlines()]
fixtures=[json.loads(l) for p in Path('Evals/fixtures').rglob('*.jsonl') for l in p.read_text().splitlines() if l.strip()]
corpus.validate_partitions(existing+rows,fixtures)
Path('.context/boundary-coverage-draft.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n' for r in rows))
print('Validated64draft training-only rows; corpus unchanged.')
