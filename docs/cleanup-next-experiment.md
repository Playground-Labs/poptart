# One controlled rehearsal experiment before changing the model approach

Status: proposed, not trained. Issue #3. Keep the round-nine step-200 4-bit model until a replacement passes the gates below. This proposal changes only the selection of 32 rehearsal records; model, prompt, validator, 48 targeted records, training budget, and validation inputs stay fixed.

## What the evidence supports

The [targeted run](../Training/runs/2026-10-20-targeted-filler/README.md) taught trailing-filler cleanup but failed retention. Step 80 improved the eight new validation cases from 4/8 to 8/8, while the existing 47 fell from 38/47 to 36/47. Three existing cases improved; five regressed. Four regressions concern vocabulary and one concerns internal filler. Three regressed plans were rejected to raw; two accepted plans omitted a requested correction. The candidate was correctly rejected.

The nine original validation failures comprise four trailing-filler failures, one internal-filler omission, one repeated-word deletion with an empty span, one incorrect vocabulary span, one question-ending decision, and one missed sentence boundary. Five failures involve malformed spans or edit categories; four involve missed/wrong cleanup decisions. The trailing-filler examples address the largest single failure group, not all nine failures.

Counts below are records containing at least one target edit of that category; columns overlap. Empty plans are counted separately. Recomputed from the committed corpus and targeted training JSONL, without model inference:

| Record type | Canonical training (262) | Old rehearsal (32) | New targeted training (48) |
| --- | ---: | ---: | ---: |
| Capitalization | 173 | 22 | 40 |
| Punctuation | 242 | 29 | 48 |
| Filler deletion | 66 | 6 | 24 |
| Repetition deletion | 31 | 7 | 0 |
| Vocabulary correction | 27 | 3 | 0 |
| Empty model plan | 20 | 3 | 0 |
| Reserved deterministic correction present | 10 | 1 | 0 |
| Internal filler deletion specifically | 4 | 0 | 0 |

“Internal” means a filler deletion starts after span zero and ends before the final span boundary, using the existing tokenizer. The four internal examples are `round2-filler-003`, `-004`, `-007`, and `-008`. Thus the failed 80-row continuation had only three vocabulary targets and **no internal-filler targets**, precisely the two behaviors that regressed. Underrepresentation is a plausible explanation, not proven causation. The canonical validation set has five vocabulary and thirteen filler records; the latter includes several filler positions.

## Smallest next intervention

Repeat the same 80-step experiment, replacing random rehearsal with 32 distinct records: 16 vocabulary, all four internal filler, four repetition, two empty plans, two questions, two reserved corrections, and two cursor-context records. Capitalization and punctuation are already exercised throughout these buckets. This is targeted retention coverage, not a claim of equal coverage of every product behavior.

Use the retained adapter, not rejected step 80. Preserve learning rate 5e-6, batch size 1, rank 8, scale 20, last 16 layers, seed 20260824, prompt masking, sequence limit 512, and checkpoints 40/80. One run only; no learning-rate sweep or extra epochs if rejected.

The following preparation command is reproducible from the repository root and writes only a fresh `.context/cleanup-balanced` directory. Freeze its resulting files and hashes before training; the canonical corpus remains unchanged.

```sh
.context/cleanup-model/venv/bin/python - <<'PY'
import hashlib, json, sys
from pathlib import Path
sys.path.insert(0, 'Training')
import prepare_corpus as p
read = lambda path: [json.loads(x) for x in Path(path).read_text().splitlines()]
source = Path('Training/runs/2026-10-20-targeted-filler')
rows = [r for r in read('Training/data/corpus.jsonl') if r['split'] == 'train']
cat = lambda r, c: any(e['c'] == c for e in r['editPlan']['e'])
buckets = [
    ('vocabulary', 16, lambda r: cat(r, 'vocabulary')),
    ('internal-filler', 4, lambda r: any(
        e['c'] == 'filler' and 0 < e['s'] < e['e'] < len(p.editplan.tokenize(r['raw']))
        for e in r['editPlan']['e'])),
    ('repetition', 4, lambda r: cat(r, 'repetition')),
    ('empty', 2, lambda r: not r['editPlan']['e']),
    ('question', 2, lambda r: any(e['c'] == 'punctuation' and e['r'] == '?'
                                for e in r['editPlan']['e'])),
    ('reserved', 2, lambda r: bool(r.get('reservedEdits'))),
    ('context', 2, lambda r: bool(r.get('targetContext'))),
]
picked, manifest = [], {}
for name, count, predicate in buckets:
    pool = sorted((r for r in rows if predicate(r) and r not in picked), key=lambda r:
        hashlib.sha256(('20261020-balanced:' + r['id']).encode()).hexdigest())
    assert len(pool) >= count, name
    selected = pool[:count]
    picked.extend(selected)
    manifest[name] = [r['id'] for r in selected]
training = picked + [r for r in read(source/'new-examples.jsonl') if r['split'] == 'train']
validation = read(source/'validation.jsonl')
assert len(training) == 80 and len(validation) == 55
seen = set()
train_messages = [p.build(r, seen) for r in training]
valid_messages = [p.build(r, seen) for r in validation]
assert not {r['raw'] for r in training} & {r['raw'] for r in validation}
out = Path('.context/cleanup-balanced')
out.mkdir(exist_ok=False)
(out/'mlx').mkdir()
for path, records in [('training.jsonl', training), ('validation.jsonl', validation),
                      ('mlx/train.jsonl', train_messages), ('mlx/valid.jsonl', valid_messages)]:
    (out/path).write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in records))
(out/'rehearsal.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest, indent=2))
PY
```

Before running, check full chat-template token lengths stay within 512 and write the frozen protocol/input hashes alongside the generated data. Then the training command is:

```sh
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
  --config Training/runs/2026-10-20-targeted-filler/training-config.yaml \
  --model .context/cleanup-model/base \
  --data .context/cleanup-balanced/mlx \
  --resume-adapter-file .context/cleanup-round8/adapters/0000200_adapters.safetensors \
  --adapter-path .context/cleanup-balanced/adapters
```

Reuse the existing export/evaluation procedure with **new paths**; do not run the old `evaluate.sh` unchanged because it points to historical output directories. Restore the base tokenizer, chat template, and license to each fused/4-bit export. Use actual Swift `CleanupEvaluation`, affine 4-bit/group-64 exports, and the frozen 55 validation cases. Include baseline in ranking. Diagnostic loss never selects a model.

## Acceptance and stopping gates

1. **Input gate:** exactly 80 unique training IDs and the same 55 validation records; all targets pass `prepare_corpus.build`, no split overlap, token lengths within 512, and input/adapter/script hashes frozen. Publish the 32 selected IDs and category counts. No evaluation cases enter training.
2. **Validation gate:** improve total exact output above baseline 42/55 and retain every one of the baseline's 38 correct existing-validation outputs. Report vocabulary, internal/trailing filler, repetition, and no-op results separately. Among eligible checkpoints choose highest total exact, ties prefer fewer steps. If neither passes, stop and retain baseline.
3. **Post-selection gate:** evaluate only the winner and baseline on the historical 79 plus the 16 unused targeted evaluation cases. Preserve all 49 previously correct non-adversarial historical outputs and improve exact output over baseline on the fresh 16. Review every changed output; reject newly accepted unsafe edits. Harmless capitalization is not automatically an adversarial safety failure merely because fallback counts differ.
4. **Decision gate:** archive hashes, resolved configuration, model outputs, category comparisons, and acceptance decision. A pass makes an experimental candidate only: synthetic development tests and M3 Pro debug timings do not satisfy release quality or the physical 8 GB M1 qualification.

The fresh 16 were not inferred on in the rejected targeted run. The 55 validation and historical 79 cases are exposed development checks. If this one controlled run fails, stop repeating this recipe and use the resulting error categories to decide whether the edit-plan representation or adaptation strategy needs a separate bounded comparison. Do not automatically change ADR 0039 or migrate frameworks.

Analysis only: no training, model inference, corpus mutation, or runtime change was performed for this proposal. The category selection was checked read-only; the preparation/training commands above have not been executed as an experiment.
