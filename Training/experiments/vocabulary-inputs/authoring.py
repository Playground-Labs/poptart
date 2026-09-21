"""Independently authored synthetic vocabulary spellings; draft training rows only."""
import json,sys
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as corpus
import editplan

# Every application/product name and utterance here is invented for this corpus.
joins = '''Blueenvelope|blue envelope|Put the invoice in blue envelope after reviewing it
Cedarport|cedar port|The team stores its reference images in cedar port
Greenbasket|green basket|Attach the revised diagram to the green basket workspace
Mossledger|moss ledger|Please check whether moss ledger finished the overnight export
Stonebridge|stone bridge|Our reading list appears in stone bridge beside the archive
Hazelford|hazel ford|Move the unsigned document into the hazel ford folder
Redlantern|red lantern|I saved a separate copy in red lantern for the editor
Tidepaper|tide paper|Add the missing caption through tide paper this afternoon
reednote|reed note|Send the rehearsal notes to reed note before tomorrow
maplebranch|maple branch|We can compare both versions inside maple branch later
meadowlink|meadow link|The invitation from meadow link arrived after breakfast
silverribbon|silver ribbon|Please attach the sketch in silver ribbon beside the outline
sandfolio|sand folio|Our photographer keeps the contact sheet in sand folio
mintledger|mint ledger|Check the totals in mint ledger before approving anything
flintpage|flint page|The navigation labels for flint page need another review
covegrid|cove grid|I placed the revised schedule in cove grid yesterday
ROCKVAULT|rock vault|Export the uncompressed recording from rock vault after lunch
COPPERKETTLE|copper kettle|The package from copper kettle includes a short introduction
PINECAST|pine cast|Please upload the interview through pine cast when it is ready
SMALLHARBOR|small harbor|Our draft in small harbor still needs an opening paragraph
LAKEFOLD|lake fold|Keep the original attachment in lake fold for reference
STARCRATE|star crate|We received the annotated proof from star crate this morning
OAKSIGNAL|oak signal|The notification from oak signal can wait until Monday
DEWMAP|dew map|Review the route in dew map before we leave'''
spaced = '''Willow Studio|willow studio|The drawings for willow studio belong in this collection
Copper Atlas|copper atlas|We can revise the legend in copper atlas after the meeting
Slate Harbor|slate harbor|Please place the receipt in slate harbor beside the invoice
Birch Lantern|birch lantern|The draft from birch lantern still has the original title
Cobalt Garden|cobalt garden|I sent the second invitation through cobalt garden yesterday
River Loom|river loom|Upload the finished pattern to river loom before the workshop
Marble Finch|marble finch|Our editor left three notes in marble finch this morning
Frost Ledger|frost ledger|Check the remaining entries in frost ledger after breakfast'''
correct = '''Cedarport|The export from Cedarport arrived in the shared inbox
reednote|Our rehearsal outline in reednote already includes the encore
ROCKVAULT|Please keep the WAV recording in ROCKVAULT until Friday
Willow Studio|The pen drawing for Willow Studio is nearly finished
Mossledger|We reviewed the archived receipt in Mossledger last night
covegrid|This covegrid calendar contains the final rehearsal dates
DEWMAP|The DEWMAP route avoids the closed footbridge
River Loom|Please preserve the original project title in River Loom'''
irrelevant = '''Blueenvelope|Put the letter in the blue envelope
Greenbasket|The wet towels belong in the green basket beside the door
Stonebridge|We crossed the stone bridge over the stream on foot
Redlantern|Please hang the red lantern from the hook above the porch
maplebranch|A squirrel ran along the maple branch above our picnic table
silverribbon|Tie the silver ribbon around the wrapped parcel
COPPERKETTLE|The copper kettle on the stove is full of hot water
SMALLHARBOR|Fishing boats filled the small harbor below the village'''
# Each distractor is itself relevant elsewhere; its identity cannot mark it irrelevant.
term_pool=list(dict.fromkeys(line.split('|')[0] for block in (joins,spaced) for line in block.splitlines()))

rows=[]
def add(group,index,term,spoken,text):
    # Both recognition-style punctuation and uncased text occur in each group.
    raw=(text[0].lower()+text[1:] if index%2 else text)+('.' if index%3==0 else '')
    clean=text.replace(spoken,term) if spoken else text
    clean += '.'
    spans=editplan.tokenize(raw)
    edits=[]
    if spoken:
        assert raw.lower().count(spoken.lower())==1
        words=spoken.split()
        matches=[i for i in range(len(spans)-len(words)+1)
                 if [s.text.lower() for s in spans[i:i+len(words)]]==words]
        assert len(matches)==1
        start=matches[0]
        edits.append(dict(s=start,e=start+len(words),r=term,c='vocabulary'))
    if spans[0].text[0].islower():
        edits.append(dict(s=0,e=1,r=spans[0].text[0].upper()+spans[0].text[1:],c='capitalization'))
    if spans[-1].text!='.':
        edits.append(dict(s=len(spans),e=len(spans),r='.',c='punctuation'))
    edits.sort(key=lambda e:(e['s'],e['e']))
    position=len(rows)
    distractor=term_pool[(position+13)%len(term_pool)]
    assert distractor!=term and distractor.lower() not in raw.lower()
    terms=[term,distractor] if (index//2)%2 else [distractor,term]
    row=dict(id=f'train-spelling-{group}-{index+1:03}',split='train',provenance=corpus.PROVENANCE,
             raw=raw,clean=clean,editPlan=dict(v=1,e=edits),vocabularyTerms=terms,
             coverage=['literal-vocabulary-spelling',group])
    corpus.build(row,set())
    rows.append(row)
for group,block in [('join',joins),('spaced',spaced)]:
    for index,line in enumerate(block.splitlines()): add(group,index,*line.split('|'))
for group,block in [('already-correct',correct),('irrelevant',irrelevant)]:
    for index,line in enumerate(block.splitlines()):
        term,text=line.split('|');add(group,index,term,None,text)
assert len(rows)==48
for group in ('join','spaced','already-correct','irrelevant'):
    group_rows=[r for r in rows if group in r['coverage']]
    for lowercase in (False,True):
        selected=[r for r in group_rows if r['raw'][0].islower()==lowercase]
        expected=[line.split('|')[0] for line in dict(join=joins,spaced=spaced,**{'already-correct':correct,'irrelevant':irrelevant})[group].splitlines()]
        positions=[r['vocabularyTerms'].index(expected[group_rows.index(r)]) for r in selected]
        assert positions.count(0)==positions.count(1)
existing=[json.loads(l) for l in Path('Training/data/corpus.jsonl').read_text().splitlines()]
fixtures=[json.loads(l) for p in Path('Evals/fixtures').rglob('*.jsonl') for l in p.read_text().splitlines() if l.strip()]
corpus.validate_partitions(existing+rows,fixtures)
Path('.context/vocabulary-spelling-draft.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n' for r in rows))
print('Validated48draft training rows:24joins,8literal-spaced names,8already-correct,8irrelevant. Corpus unchanged.')
