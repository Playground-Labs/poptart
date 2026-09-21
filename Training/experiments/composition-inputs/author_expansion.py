"""Authored training-only coverage; no fixture text is used to construct examples."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as corpus
import editplan

new = []
def edit(s, e, r, c):
    return dict(s=s, e=e, r=r, c=c)
def add(group, index, raw, clean, edits, **extra):
    row = dict(id=f'train-composition-{group}-{index+1:03}', split='train',
               provenance=corpus.PROVENANCE, raw=raw, clean=clean,
               coverage=[group, 'composed-edits'], editPlan=dict(v=1, e=edits), **extra)
    corpus.build(row, set())
    new.append(row)
def shaped(text, index):
    return (text[0].lower() + text[1:] if index % 2 else text) + ('.' if index % 3 == 0 else '')
def finish(raw, edits):
    spans = editplan.tokenize(raw)
    if spans[0].text[0].islower():
        edits.append(edit(0, 1, spans[0].text[0].upper() + spans[0].text[1:], 'capitalization'))
    if spans[-1].text != '.':
        edits.append(edit(len(spans), len(spans), '.', 'punctuation'))
    return sorted(edits, key=lambda e: (e['s'], e['e']))

# Nouns and verbs in distinct invented utterances, with varied casing and punctuation.
repetitions = '''The violin case belongs beside the piano|case
A copper kettle whistles on the stove|kettle
The lighthouse lamp needs a fresh bulb|lamp
Our terrier sleeps under the bench|terrier
The shuttle leaves from the eastern depot|shuttle
A wooden crate holds the spare hinges|crate
The baker stacked the cooled pastries|baker
Our canoe rests near the fallen birch|canoe
The velvet curtain conceals a small alcove|curtain
A red tractor blocks the gravel lane|tractor
The dentist postponed the afternoon appointment|dentist
Our lantern lights the narrow tunnel|lantern
Please fasten the buckle around the trunk|fasten
We borrowed a ladder from the neighbour|borrowed
The assistant sorted the returned uniforms|sorted
Please inspect the cushion seams carefully|inspect
Our scouts collected enough dry kindling|collected
The diver located the sunken anchor|located
Please replace the cracked ceramic tile|replace
We ordered a smaller kitchen extractor|ordered
The carpenter sanded the rounded handle|sanded
Please arrange the postcards by destination|arrange
Our guide explained the ancient inscription|explained
The children painted the cardboard castle|painted
The narrow bridge leads toward the mill|bridge
We need clean containers for the soup|containers
A heavy chain secures the bicycle rack|chain
The purple ribbon matches her embroidered bag|ribbon
Our quiet neighbour tends the rooftop roses|neighbour
A shallow tray catches the dripping water|tray
The damaged wheel came from the handcart|wheel
We found fresh tracks beside the stream|tracks
A striped awning shades the corner stall|awning
The upper balcony faces the railway station|balcony
Our spare mattress fits the guest bedroom|mattress
The polished brass knob turns without effort|knob
Please gently brush the mud from the boots|brush
The caretaker carefully wrapped the cracked vase|wrapped
We finally located the vanished door key|located
The swimmer slowly crossed the chilly channel|crossed
Please firmly press the seal against the lid|press
Our driver safely negotiated the icy bend|negotiated
The instructor clearly described the rescue procedure|described
We recently repaired the leaking garden tap|repaired
Please neatly stack the folded tablecloths|stack
The courier promptly returned the unsigned form|returned
Our drummer quietly adjusted the loose cymbal|adjusted
The pilot calmly explained the minor delay|explained'''.splitlines()
for i, line in enumerate(repetitions):
    text, word = line.split('|')
    start = text.split().index(word)
    words = text.split(); words.insert(start, word)
    raw = shaped(' '.join(words), i)
    edits = finish(raw, [edit(start, start + 1, '', 'repetition')])
    add('repetition', i, raw, text + '.', edits)

commands = '''Lift this lid
Turn it clockwise
Take your umbrella
Hold that ladder
Pass those tongs
Check the gauge
Mend this seam
Tie the knot
Lower the canopy
Raise your hand
Bring the harness
Place it upright
Leave us space
Keep them level
Push the lever
Pull it gently
Press this switch
Rest your wrist
Wash those plums
Dry that pan
Warm the milk
Chill this custard
Beat the batter
Slice the melon
Peel this peach
Stir the broth
Strain those berries
Grate the cheese
Sift this flour
Butter that shallow dish
The falcon returned to its perch
Our coach postponed the rowing lesson
Please unlock the painted storage chest
We rented a cabin near the marsh
The potter wrapped each glazed saucer
Our new awning covers the entryway
Please refill the hummingbird feeder
We stitched a patch inside the sleeve
The curator examined the ivory compass
Our canoe club meets beside the reservoir'''.splitlines()
for i, text in enumerate(commands):
    filler = 'uh' if (i // 2) % 2 else 'um'
    raw = shaped(text + ' ' + filler, i)
    start = len(editplan.tokenize(text))
    add('terminal-filler', i, raw, text + '.', finish(raw, [edit(start, start + 1, '', 'filler')]))

vocabulary = '''Keep the rehearsal seating chart in|pebble note|PebbleNote|until the choir arrives
Please check the inventory record in|amber grid|AmberGrid|before ordering replacement jars
Our rowing team uses|tidal page|TidalPage|to arrange practice sessions
Send the revised costume measurements through|velvet post|VelvetPost|before the fitting
Save the pottery kiln schedule in|clay atlas|ClayAtlas|for the visiting instructors
Please archive the orchard yield figures in|plum tally|PlumTally|after the harvest
We share the lantern parade route through|glow map|GlowMap|with every volunteer
Keep the bicycle repair estimates inside|spoke file|SpokeFile|for future reference
Our puppet troupe keeps its scripts in|felt folio|FeltFolio|during the tour
Please enter the greenhouse temperatures in|sprout log|SproutLog|before closing the vents
Store the sailing club minutes in|mast ledger|MastLedger|for the committee
We prepare the chess tournament pairings with|rook chart|RookChart|before each round
Please upload the campsite layout to|camp slate|CampSlate|so the wardens can review it
Keep the museum audio guide drafts in|echo shelf|EchoShelf|until recording begins
Our ceramic supplier sends invoices through|glaze mail|GlazeMail|every fortnight
Please update the violin repair register in|bow index|BowIndex|before collecting the instrument
We track the annual seed exchange in|seed weave|SeedWeave|throughout the spring
Save the fishing permit details in|reed pocket|ReedPocket|before the weekend outing
Please send the bookbinding design through|spine sketch|SpineSketch|for approval
Our bird survey results belong in|wing count|WingCount|beside the earlier observations
Leave the revised stained glass drawing in|prism pad|PrismPad|for the restorer
Please record the soup kitchen donations in|ladle book|LadleBook|after counting the tins
We keep the mountaineering equipment list in|crag list|CragList|for the expedition leader
Upload the beekeeping inspection notes to|hive desk|HiveDesk|before cleaning the tools
Our fountain maintenance records live in|pool archive|PoolArchive|with the original plans
Please check the embroidery thread order in|stitch board|StitchBoard|before contacting the supplier
Save the astronomy lecture outline in|star quill|StarQuill|for tomorrow evening
We store the dog training timetable in|paw planner|PawPlanner|for the new instructors
Please log the restored clock measurements in|dial trace|DialTrace|after testing the mechanism
Our bakery delivery routes are listed in|loaf route|LoafRoute|for every driver
Put the wildlife shelter roster in|burrow sheet|BurrowSheet|before the next shift
Please send the weaving workshop invitation through|loom link|LoomLink|to the registered guests
We keep the railway model photographs in|rail album|RailAlbum|for the exhibition catalogue
Save the canoe restoration receipts in|paddle vault|PaddleVault|until reimbursement arrives
Our fencing association records attendance in|foil roster|FoilRoster|after each lesson
Please open the festival lighting diagram in|beam canvas|BeamCanvas|before mounting the brackets
We organize the coastal litter survey with|shore stack|ShoreStack|every month
Keep the restored telescope sketches in|lens nest|LensNest|beside the equipment register
Please send the leatherwork patterns through|hide folder|HideFolder|to the workshop tutor
Our sailing instructors use|sail signal|SailSignal|to share weather cancellations'''.splitlines()
for i, line in enumerate(vocabulary):
    prefix, wrong, right, suffix = line.split('|')
    text = f'{prefix} {wrong} {suffix}'
    raw = shaped(text, i)
    start = len(editplan.tokenize(prefix))
    add('vocabulary', i, raw, f'{prefix} {right} {suffix}.',
        finish(raw, [edit(start, start + 2, right, 'vocabulary')]), vocabularyTerms=[right])

preserve = '''I knew that that cupboard was already empty.
The caretaker had had the lock replaced last week.
We can can the remaining peaches tomorrow.
She said that that narrow lane leads to the quay.
The baker had had enough dough for another loaf.
It is a very very steep climb beyond the cairn.
I had had this particular umbrella for years.
Do you think that that painted sign is legible?
The seamstress had had trouble threading the needle.
We all agreed that that chair belonged upstairs.
This is a very very delicate antique brooch.
I mean the larger of the two measuring spoons.
The house looks like an old railway cottage.
I like the uneven glaze on those blue bowls.
Please preserve the literal text um in the quoted example.
The abbreviation UH identifies the university here.
That is what I mean by an adjustable clasp.
It felt like a sensible route around the marsh.
I like how this adjustable hinge closes softly.
Keep the phrase uh oh exactly as it appears.'''.splitlines()
for i, text in enumerate(preserve):
    add('preservation', i, text, text, [])

existing = [json.loads(s) for s in Path('Training/data/corpus.jsonl').read_text().splitlines()]
# Fixtures are read only by the pre-existing duplicate guard, never by the authoring logic.
fixtures = [json.loads(s) for p in Path('Evals/fixtures').rglob('*.jsonl') for s in p.read_text().splitlines() if s.strip()]
corpus.validate_partitions(existing + new, fixtures)
Path('.context/composition-corpus.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n' for row in new))
print(f'Validated {len(new)} draft training records; existing corpus unchanged.')
