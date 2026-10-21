"""Change only the hybrid edit discriminator; reuse verified prior control predictions."""
import json,sys,hashlib,shutil
from pathlib import Path
sys.path.insert(0,'Training')
import prepare_corpus as p
import uniform_operations as uniform
root=Path(__file__).resolve().parent
previous=Path('Training/runs/2026-10-20-typed-operations')
out=Path('.context/cleanup-uniform');(out/'mlx').mkdir(parents=True,exist_ok=False)
load=lambda f:[json.loads(x) for x in f.read_text().splitlines()]
for split,filename in [('train','training.jsonl'),('valid','validation.jsonl')]:
 rows=load(previous/filename);messages=[]
 for row in rows:
  message=p.build(row,set());document=uniform.encode(row['editPlan'],row['raw'])
  assert uniform.compile_plan(document,row['raw'])==row['editPlan']
  result=uniform.resolve_output(row,json.dumps(document)+'<END_PLAN>')
  assert result['output']==row['clean'] and result['outcome']=='cleaned'
  message['messages'][0]['content']=uniform.SYSTEM
  message['messages'][-1]['content']=json.dumps(document,separators=(',',':'),ensure_ascii=False)+'<END_PLAN>'
  messages.append(message)
 (out/'mlx'/f'{split}.jsonl').write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in messages))
 shutil.copy(previous/filename,root/filename)
for name in ('evaluation.jsonl','training-config.yaml','retainedBaseline-predictions.jsonl','range-predictions.jsonl'):
 shutil.copy(previous/name,root/name)
protocol={'releaseQualified':False,'purpose':'One-variable follow-up to hybrid schema operation collapse; every operation now begins with o. No extra data or steps.','startingAdapter':'.context/cleanup-round8/adapters/0000200_adapters.safetensors','trainingRows':100,'lossValidationRows':67,'evaluationRows':91,'steps':100,'learningRate':1e-5,'seed':20260824,'checkpointsEvaluated':[100],'cachedControls':'Exact retainedBaseline/range prediction bytes from 2026-10-20-typed-operations; matched data, adapter, optimizer and runtime. Hybrid29/91 is descriptive reference only.','selection':'Uniform must improve total exact over BOTH retained and range controls, preserve all correct outputs from each, and improve at least one punctuation/filler/context group over both. Otherwise reject.','conditionalGate':'If eligible, paired historical79+fresh16 and native compiler parity before any promotion. No app schema change here.','stop':'One100-step run. No post-result schema/prompt/data/budget revisions. If discriminator change fails, stop short schema-migration continuations and reassess full-task training.'}
(root/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
paths=[*root.glob('*'),Path('Training/uniform_operations.py'),Path('Training/test_uniform_operations.py'),Path('Training/typed_operations.py'),Path('Training/prepare_corpus.py'),Path('Training/evaluate_candidate.py'),Path('Evals/editplan.py'),Path(protocol['startingAdapter']),*out.glob('mlx/*.jsonl')]
(root/'input-hashes.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in paths if f.is_file()},indent=2)+'\n')
print('Prepared100/67 matched examples; copied91-case controls unchanged')
