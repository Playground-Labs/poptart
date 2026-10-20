"""Diagnostic on the fixed training sample; run from repository root."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as corpus
import evaluate_candidate as evaluation
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

out = Path('Training/runs/2026-10-17-round6')
records = [json.loads(x) for x in Path('Training/runs/2026-10-17-round4/training-sample.jsonl').read_text().splitlines()]
prior = {r['id']: r for r in map(json.loads, Path('Training/runs/2026-10-17-round4/training-candidate.jsonl').read_text().splitlines())}
baseline = {r['id']: r for r in map(json.loads, Path('Training/runs/2026-10-17-round5/baseline.jsonl').read_text().splitlines())}
assert len(records) == len(prior) == len(baseline) == 24
model, tokenizer = load('.context/cleanup-round6/candidate-4bit', tokenizer_config={'trust_remote_code': False})
rows = []
with (out / 'training-candidate.jsonl').open('x') as f:
    for record in records:
        prompt = tokenizer.apply_chat_template([{'role':'system','content':corpus.SYSTEM}, {'role':'user','content':prior[record['id']]['prompt']}], tokenize=True, add_generation_prompt=True, enable_thinking=False)
        generated = ''
        stream = stream_generate(model, tokenizer, prompt=prompt, max_tokens=128, sampler=make_sampler(temp=0))
        try:
            for token in stream:
                generated += token.text
                if '<END_PLAN>' in generated: break
        finally:
            stream.close()
        row = dict(id=record['id'], generated=generated, **evaluation.resolve_output(record,generated))
        rows.append(row)
        f.write(json.dumps(row)+'\n')
        f.flush()
        print(record['id'],row['output']==record['clean'],flush=True)
candidate = {r['id']:r for r in rows}
report = {'releaseQualified':False,'baselineExact':sum(baseline[r['id']]['output']==r['clean'] for r in records),'candidateExact':sum(candidate[r['id']]['output']==r['clean'] for r in records),'improved':[r['id'] for r in records if baseline[r['id']]['output']!=r['clean'] and candidate[r['id']]['output']==r['clean']],'regressed':[r['id'] for r in records if baseline[r['id']]['output']==r['clean'] and candidate[r['id']]['output']!=r['clean']]}
(out/'training-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report),flush=True)
