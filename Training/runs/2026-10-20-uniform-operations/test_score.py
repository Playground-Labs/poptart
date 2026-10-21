"""Positive and negative controls for the frozen comparison rule."""
import json,subprocess,sys,tempfile,shutil
from pathlib import Path
root=Path(__file__).resolve().parent
fixtures=[json.loads(x) for x in (root/'evaluation.jsonl').read_text().splitlines()]
with tempfile.TemporaryDirectory() as directory:
 temp=Path(directory)
 for name in ('evaluation.jsonl','score.py'):shutil.copy(root/name,temp)
 def write(arm,rows):(temp/(arm+'-predictions.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in rows))
 def eligible():
  subprocess.run([sys.executable,str(temp/'score.py')],check=True,capture_output=True)
  return json.loads((temp/'comparison.json').read_text())['uniformEligibleForBroaderEvaluation']
 base=[{'id':f['id'],'output':f['expected'] if i==0 else 'wrong','outcome':'cleaned','elapsedMilliseconds':1} for i,f in enumerate(fixtures)]
 for arm in ('retainedBaseline','range','uniform'):write(arm,base)
 assert not eligible()
 candidate=[dict(r,output=f['expected']) for r,f in zip(base,fixtures)];write('uniform',candidate);assert eligible()
 candidate[0]['output']='regression';write('uniform',candidate);assert not eligible()
 candidate.pop();write('uniform',candidate)
 assert subprocess.run([sys.executable,str(temp/'score.py')],capture_output=True).returncode!=0
print('Matched-comparison scorer controls passed')
