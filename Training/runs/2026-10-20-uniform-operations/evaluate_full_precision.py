"""Frozen Python feasibility comparison; uniform compiler is not in the Swift app."""
import argparse,json,sys,time
from pathlib import Path
sys.path.insert(0,'Training')
import uniform_operations as uniform
import prepare_corpus as corpus
from evaluate_candidate import resolve_output

root=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('arm',choices=['retainedBaseline','range','uniform-fp'])
parser.add_argument('model',type=Path)
args=parser.parse_args()
output=root/(args.arm+'-predictions.jsonl')
if output.exists():raise SystemExit('refusing to overwrite predictions')
from mlx_lm import load,stream_generate
from mlx_lm.sample_utils import make_sampler
model,tokenizer=load(str(args.model),tokenizer_config={'trust_remote_code':False})
fixtures=[json.loads(x) for x in (root/'evaluation.jsonl').read_text().splitlines()]
system=uniform.SYSTEM if args.arm=='uniform-fp' else corpus.SYSTEM
with output.open('x') as file:
 for fixture in fixtures:
  record=dict(fixture)
  if isinstance(record.get('targetContext'),str):record['targetContext']=dict(corpus.editplan.DEFAULT_TARGET_CONTEXT,textBeforeCursor=record['targetContext'])
  prompt=corpus.user_message(record,corpus.editplan.tokenize(record['raw']))
  messages=[{'role':'system','content':system},{'role':'user','content':prompt}]
  tokens=tokenizer.apply_chat_template(messages,tokenize=True,add_generation_prompt=True,enable_thinking=False,return_dict=False)
  start=time.perf_counter();generated='';count=0
  stream=stream_generate(model,tokenizer,prompt=tokens,max_tokens=128,sampler=make_sampler(temp=0))
  try:
   for response in stream:
    generated+=response.text;count+=1
    if corpus.editplan.STOP_MARKER in generated:break
  finally:stream.close()
  result=uniform.resolve_output(record,generated) if args.arm=='uniform-fp' else resolve_output(record,generated)
  row=dict(id=record['id'],**result,generated=generated,inputTokens=len(tokens),outputTokens=count,elapsedMilliseconds=(time.perf_counter()-start)*1000,systemInstruction=system,prompt=prompt,releaseQualified=False)
  file.write(json.dumps(row,ensure_ascii=False)+'\n');file.flush()
  print(args.arm,record['id'],result['output']==record['expected'],flush=True)
print(f'Completed {len(fixtures)} records; Python diagnostic only',flush=True)
