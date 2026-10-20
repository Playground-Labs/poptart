# Focused training-fit experiment

**Outcome: diagnostic improvement, not a replacement or release candidate.**
The exported 4-bit model fixes all seven errors in the fixed training sample,
retains all seventeen passing controls, and improves on twelve newly authored
cases. It also introduces three regressions on existing development cases and
loses to the starting checkpoint on validation loss.

## Method

Continue round four's selected adapter for 200 steps on the fixed 24-record
training sample from `../2026-10-17-round4/training-sample.jsonl`. No new training
examples, prompt changes, or validator changes. The 29 validation records remain
unchanged. Run `sh Training/runs/2026-10-17-round6/reproduce.sh` from the repository
root using fresh output directories. The script rebuilds and validates the subset.
`training-arguments.json` captures resolved options; resuming restores adapter
weights but resets optimizer state. Peak MLX memory was 15.077 GB.

Checkpoint selection was declared before training: lowest validation loss,
including the starting adapter; ties prefer fewer additional steps. Measured
losses: baseline 0.042, step 100 0.044, step 200 0.048. **Baseline wins.** Step 100
was separately exported solely to measure whether the model can learn valid
plans. This diagnostic export does not override the selection decision.

Fuse `.context/cleanup-round6/diagnostic-adapters` (step 100 and its adapter config)
against the pinned base using the recipe in `../../README.md`; quantize with
4-bit affine, group size 64. Preserve the pinned tokenizer files, chat template,
and license in both export directories. The local export lives at
`.context/cleanup-round6/candidate-4bit`; despite that directory name, it was
rejected as a replacement. File hashes are in `candidate-4bit-artifact.json`.

## Results

| Exact output | Round-four 4-bit | Focused diagnostic 4-bit |
| --- | ---: | ---: |
| Fixed training sample, Python MLX | 17/24 | 24/24 |
| Gold, Swift | 6/12 | 6/12 |
| Original holdout, Swift | 5/8 | 5/8 |
| Round-two holdout, Swift | 8/12 | 9/12 |
| Round-three holdout, Swift | 2/8 | 4/8 |
| Newly authored unseen set, Swift | 4/12 | 7/12 |

The existing non-adversarial development total improves from 21/40 to 24/40,
with six improvements and three regressions. These totals are exact outputs,
not a combined metric for the separate quality dimensions. Full dimensions and
case IDs are retained in `development-comparison.json` and
`unseen-comparison.json`. The small unseen set is authored synthetic material,
validated and frozen before inference, never used for training or checkpoint
selection; it is not representative release qualification. It is now exposed to
development. The broader existing sets were already exposed before this run.

The three regressions are `gold-009` (invalid punctuation span, fallback),
`round2-correction-013` (punctuation touches a reserved correction, fallback), and
`round3-filler-013` (missing initial capitalization). Gold meaning-preservation
checks decline from 9/12 to 7/12. The validator still rejects invalid plans.

The historical strict adversarial fallback count improves from 5/11 to 10/11.
This metric counts every accepted plan as failure, including safe edits. The one
accepted case only capitalizes the transcript's first word and adds a period;
see `adversarial-review.json`. More fallbacks alone do not prove better safety.

`evaluate_fit.py` reproduces the Python diagnostic against round five's saved
baseline. Swift evaluation used the existing `CleanupEvaluation` executable:
concatenate `.context/cleanup-round3/fixtures.jsonl` and `unseen.jsonl` into one
63-case file, then run the round-six export. Separately run the round-four export
on `unseen.jsonl`. Both processes completed with exit 0. Full raw predictions are
retained; the 63-case output is also split into development/unseen files for the
existing comparison helper. All use the unchanged production prompt and validator,
128 output tokens, and diagnostic 30-second deadline. M3 Pro debug timings are
not physical 8 GB M1 release benchmarks.

## Decision

The model can learn the valid edit plans, and some improvement survives
quantization and reaches unseen examples. Concentrating on only 24 examples
also loses broader behavior. The next training change should retain the full
172-record training distribution while increasing exposure to the error cases,
then use validation selection and the same separate runtime quality checks.
Do not promote this narrow fine-tune or weaken the validator.

No release metadata changed and no weights were published. Model quality and the
physical M1 benchmark remain launch blockers. All 18 tooling tests pass and
`git diff --check` passes.
