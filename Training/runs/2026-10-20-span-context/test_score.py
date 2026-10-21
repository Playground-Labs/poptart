"""Synthetic positive/negative controls for the diagnostic selection rule."""
import json,tempfile,shutil,subprocess,sys
from pathlib import Path
r=Path(__file__).resolve().parent
fixtures=[json.loads(x) for x in (r/'fixtures.jsonl').read_text().splitlines()]
with tempfile.TemporaryDirectory() as d:
 p=Path(d)
 for n in ('fixtures.jsonl','score.py','boundary.txt','context.txt'):shutil.copy(r/n,p)
 baseline=[dict(id=f['id'],output=f['expected'] if i==0 else f['raw'],outcome='cleaned',elapsedMilliseconds=1,systemInstruction='test system',prompt='fixture',inputTokens=100) for i,f in enumerate(fixtures)]
 def write(n,rows):(p/n).write_text(''.join(json.dumps(x)+'\n' for x in rows))
 def score():
  subprocess.run([sys.executable,str(p/'score.py')],check=True,capture_output=True)
  return json.loads((p/'comparison.json').read_text())
 write('baseline.jsonl',baseline)
 for arm in ('boundary','context'):
  write(arm+'.jsonl',[dict(x,systemInstruction=x['systemInstruction']+(p/(arm+'.txt')).read_text(),inputTokens=150,output=f['expected']) for x,f in zip(baseline,fixtures)])
 assert all(v['promising'] for k,v in score().items() if k!='baseline')
 changed=[json.loads(x) for x in (p/'boundary.jsonl').read_text().splitlines()];changed[0]['output']='wrong';write('boundary.jsonl',changed)
 assert not score()['boundary']['promising']
 changed.pop();write('boundary.jsonl',changed)
 assert subprocess.run([sys.executable,str(p/'score.py')],capture_output=True).returncode!=0
 print('Scorer controls passed: improvement accepted, regression and incomplete predictions rejected')
