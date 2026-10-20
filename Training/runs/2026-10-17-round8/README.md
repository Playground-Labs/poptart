# Broader training coverage and frozen evaluation

**Outcome: reject this continuation under its predeclared checkpoint rule.**
The starting checkpoint remains round seven. Its first evaluation on sixteen
separately authored cases produces 8/16 exact outputs, confirming substantial
quality gaps. No new model was exported or promoted.

## Data

Added 90 training and 18 validation records to the canonical corpus, bringing
its splits to 262 train, 47 validation, and the unchanged 8 original test records.
`new-examples.jsonl` preserves the exact additions. Ten training-only and two
validation-only sentence topics each have eight variants: a statement, existing
capitalization, two leading fillers, a trailing filler, repetition, a sentence
continuation, and a new sentence after context. Ten further training and two
validation vocabulary examples vary the name and position of the vocabulary span.
These are systematic synthetic variants, not 108 independently sampled utterances.

`author_examples.py` records the authored text and target plans. It validates all
targets against the existing parser/validator mirror, resolves them to explicit
expected clean strings, and checks normalized-text split separation. Its two output
files must be moved aside before reproducing authoring; it ignores this round's
already-added canonical rows when checking previous text. `Training/prepare_corpus.py`
regenerates the canonical MLX files. Every sequence fits the 512-token limit:
maximum 424 training / 408 validation tokens (`sequence-lengths.json`).

Sixteen separate authored evaluation sentences were frozen in `independent.jsonl`
and `Training/data/round8-holdout.jsonl` before training or model inference. They
were never added to training or validation and never used for checkpoint selection.
The tooling suite validates their targets and checks separation from corpus and
existing fixtures. This is a small synthetic, failure-focused set; it does not
represent unbiased real-user evaluation. After this report it is exposed to
development and must not be relabeled as fresh in future comparisons.

## Training

Start from round seven's selected adapter; use all 262 training records once per
epoch, with no oversampling. Resuming restores adapter weights but resets optimizer
state. Other settings match the previous run. Reproduce from repository root with
fresh output directories and the exact input hashes in `inputs.json`:

```sh
python3 Training/prepare_corpus.py
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
  --config Training/runs/2026-10-17-round8/training-config.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 200 --max-seq-length 512 \
  --resume-adapter-file .context/cleanup-round7/selected-adapters/adapters.safetensors \
  --adapter-path .context/cleanup-round8/adapters
```

`training-arguments.json` contains resolved arguments. Peak MLX memory was
16.211 GB. The initial validation pass took 75 seconds; later passes took about
7 seconds and training returned to approximately 0.4–0.45 steps per second.
No system power settings were changed.

The selection rule was lowest expanded-validation loss, including the starting
checkpoint, with ties favoring fewer added steps. Logged losses, to three decimal
places, were baseline 0.031, step 100 0.031, and step 200 0.034. Baseline wins.
The expanded set differs from prior rounds, so these losses must not be compared
directly to prior rounds' smaller-validation-set numbers. The new checkpoints'
actual cleanup outputs were not evaluated; rejection is based on the declared
loss criterion, not a claim that their exact-output accuracy was measured worse.

## Retained model's evaluation

The retained round-seven 4-bit model was evaluated through the actual Swift engine:

```sh
swift run --package-path Packages/Cleanup CleanupEvaluation \
  .context/cleanup-round7/candidate-4bit Training/data/round8-holdout.jsonl \
  Training/runs/2026-10-17-round8/independent-baseline.jsonl
```

Use a new output path when reproducing. All sixteen cases completed, exit 0.
`independent-baseline.jsonl` retains prompts, generations, outputs, and rejections;
`independent-report.json` records separate existing quality dimensions and all
failures. Exact outputs: 8/16. Seven failures are accepted incomplete/wrong cleanup;
one is a rejected invalid plan with raw fallback. The model misses both vocabulary
edits and both repetition removals, misses two filler cases, omits capitalization
after a leading filler, and capitalizes a sentence continuation. These observations
concern this set only. The generic vocabulary-preservation metric has zero applicable
cases because no configured vocabulary term appears verbatim in the raw text; that
metric measures preservation of existing terms, not correction of spoken variants.
Exact outputs expose the vocabulary-correction failures.

The previous 32/52 development result for this unchanged model is historical,
not remeasured here. Debug M3 Pro timing with 128 output tokens and a diagnostic
30-second deadline does not qualify physical 8 GB M1 performance.

## Decision and next boundary

Retain the expanded corpus and regression fixtures as development material, and
keep round seven as the experimental model. There is no release promotion.
Repeated low token losses still coexist with missed substantive edits. Before
another training run, measure whole-plan validation outputs for the existing
checkpoints and define a task-level selection rule using validation data only.
That would test whether token-loss ranking aligns with the behavior we need,
without choosing checkpoints on the newly exposed evaluation cases.

All 18 Python tooling tests pass; `git diff --check` passes. Model quality and the
physical M1 benchmark remain launch blockers. No weights were published and no
production prompt, validator, or release metadata changed.
