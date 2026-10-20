"""Run from repository root with the local MLX venv; diagnostic only."""
import json
import sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as corpus
import evaluate_candidate as evaluation
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

ROOT = Path('Training/runs/2026-10-17-round5')
MODEL = '.context/cleanup-round4/candidate-4bit'
BASELINE = corpus.SYSTEM
CANDIDATE = BASELINE + ' Do not emit edits whose replacement is identical to the source text. Words already capitalized, including I, need no capitalization edit.'
records = [json.loads(line) for line in Path('Training/runs/2026-10-17-round4/training-sample.jsonl').read_text().splitlines()]
prior = {row['id']: row for row in map(json.loads, Path('Training/runs/2026-10-17-round4/training-candidate.jsonl').read_text().splitlines())}
assert len(records) == 24 and len(prior) == 24
model, tokenizer = load(MODEL, tokenizer_config={'trust_remote_code': False})
results = {}
for name, system in [('baseline', BASELINE), ('candidate', CANDIDATE)]:
    path = ROOT / (name + '.jsonl')
    with path.open('x') as output:
        rows = []
        for record in records:
            prompt = tokenizer.apply_chat_template([
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': prior[record['id']]['prompt']}],
                tokenize=True, add_generation_prompt=True, enable_thinking=False)
            generated = ''
            stream = stream_generate(model, tokenizer, prompt=prompt, max_tokens=128, sampler=make_sampler(temp=0))
            try:
                for token in stream:
                    generated += token.text
                    if '<END_PLAN>' in generated:
                        break
            finally:
                stream.close()
            row = {'id': record['id'], 'generated': generated, **evaluation.resolve_output(record, generated)}
            rows.append(row)
            output.write(json.dumps(row) + '\n')
            output.flush()
            print(name, record['id'], row['output'] == record['clean'], flush=True)
        results[name] = rows
baseline = {row['id']: row['output'] for row in results['baseline']}
candidate = {row['id']: row['output'] for row in results['candidate']}
report = {
    'releaseQualified': False,
    'model': MODEL,
    'systemPrompts': {'baseline': BASELINE, 'candidate': CANDIDATE},
    'baselineExact': sum(baseline[r['id']] == r['clean'] for r in records),
    'candidateExact': sum(candidate[r['id']] == r['clean'] for r in records),
    'improvements': [r['id'] for r in records if baseline[r['id']] != r['clean'] and candidate[r['id']] == r['clean']],
    'regressions': [r['id'] for r in records if baseline[r['id']] == r['clean'] and candidate[r['id']] != r['clean']],
}
(ROOT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report), flush=True)
