# Targeted trailing-filler correction: reject both checkpoints

The targeted behavior is learnable, but this continuation loses existing quality.
Retain the previous experimental model at `.context/cleanup-round9/step-200/candidate-4bit`.
No app behavior, production prompt, validator, release metadata, or shipped model changed.

| Additional steps | Existing validation | Fresh validation | Total | Eligible |
| --- | ---: | ---: | ---: | --- |
| 0 | 38/47 | 4/8 | 42/55 | Yes |
| 40 | 34/47 | 6/8 | 40/55 | No |
| 80 | 36/47 | 8/8 | 44/55 | No |

## Diagnosis and frozen experiment

`failure-analysis.json` classifies all nine current validation failures. Five involve
filler removal, including four trailing-filler cases: wrong edit category, an empty
deletion span, or punctuation inserted before the retained filler. Other failures
include vocabulary spans, repeated-word bounds, question punctuation, and sentence
boundary decisions. This is a mix of edit-selection and span/category errors.

Before training, `protocol.json` fixed an 80-step pass at learning rate 5e-6,
starting from the retained round-eight step-200 adapter, checkpoints at 40/80,
and exact-output selection through Swift at 4-bit precision. Eligibility requires
at least 38/47 existing exact outputs; eligible candidates rank by all 55 exact
outputs, ties preferring fewer added steps. Both new checkpoints fail eligibility.

The 80 training records comprise 48 new examples (24 sentence pairs with/without
trailing um/uh) and 32 deterministically sampled existing training records. Four
new paired sentence topics form eight validation cases; eight additional topics
form sixteen evaluation cases. No topic crosses splits. New raw inputs were checked
against historical raw/clean/expected text, and all targets passed the existing
validator and provenance checks. Sequence lengths max at 396 training and 408
validation tokens under the 512-token limit. The canonical corpus is unchanged.

`prepare.py` reproduces the isolated dataset in fresh output paths. It refuses to
overwrite data files. `inputs.json` hashes the declared inputs, starting adapter,
and scripts. `training.log` and `resolved-training-args.json` preserve the run.
Loss moved from 0.034 initially to 0.038 at step 40 and 0.024 at step 80; peak MLX
memory was 15.026 GB. Loss did not override whole-output selection.

## Regression review and decision

At step 80, three existing trailing-filler cases improve and all four new filler
validation cases improve. Five existing cases regress: four vocabulary cases and
one internal-filler case. Three regressions are invalid plans rejected to raw;
two accepted plans omit the desired vocabulary/filler correction. Full plans and
resolved text are in `regression-review.json`; separate quality dimensions and
all improvement/regression IDs are in `comparison-*.json`.

The randomly chosen rehearsal set contains only three records with vocabulary
edits. That weak coverage is a plausible contributor to the vocabulary regressions,
not a proven causal explanation. This result does not show that the architecture
is incapable of the task. It shows that this narrow continuation is not sufficient
and should not replace the existing model, despite a better total score on the
expanded validation set.

No new checkpoint reached the post-selection gate, so the broader 79-case suite
and sixteen fresh evaluation cases were not run. The latter remain unused for
model inference. Adversarial safety for these rejected weights is unassessed; the
existing model's prior evidence is unchanged. No new release-quality claim is made.

Future model work should address retention across task categories explicitly,
with category-balanced rehearsal and fixed validation constraints, rather than
repeat this random rehearsal recipe or assume more epochs solve the failures.
The representation/model decision can be revisited separately if balanced training
also fails; this experiment alone does not justify changing ADR 0039.

## Reproduction and verification

Run from repository root with the pinned local environment and assets:

```sh
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
  --config Training/runs/2026-10-20-targeted-filler/training-config.yaml \
  --model .context/cleanup-model/base \
  --data Training/runs/2026-10-20-targeted-filler/mlx \
  --resume-adapter-file .context/cleanup-round8/adapters/0000200_adapters.safetensors \
  --adapter-path .context/cleanup-targeted/adapters
sh Training/runs/2026-10-20-targeted-filler/evaluate.sh
```

Use fresh export and prediction paths. The evaluator runs baseline and both
checkpoints on the frozen 55 cases, then scores the declared selection rule.
Training and all three native evaluation processes exited zero. Baseline reproduced
38/47. Both exports preserve the base tokenizer, template, and license by hash;
`artifact-*.json` records export hashes. All frozen input hashes still match.
20 Python tooling tests, shell syntax checking, and `git diff --check` pass.
These debug M3 Pro runs do not satisfy the physical 8 GB M1 deadline gate.
