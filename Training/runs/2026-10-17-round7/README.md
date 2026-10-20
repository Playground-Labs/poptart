# Balanced error-focused continuation

**Outcome: improved aggregate development accuracy, still not release-ready.**
Validation loss improves, and the 4-bit model reaches 32/52 exact non-adversarial
outputs versus 25/52 for round four and 31/52 for the narrow round-six diagnostic.
It still regresses on individual cases, including a passing training control.
No production prompt, validator, release metadata, or published weights changed.

## Training and selection

Start from round four's selected adapter. Keep all 172 training records and add
seven extra copies of each of its seven fixed training-sample failures, producing
221 weighted rows (each failure appears eight times). No development or validation
record enters training. The 29 validation records remain unchanged. The canonical
corpus and generated training files are unchanged; weighting is local to this run.
`prepare_data.py` validates targets, checks record counts, and records failure IDs
and hashes in `inputs.json`.

Use fresh output directories to reproduce from the repository root:

```sh
python3 Training/runs/2026-10-17-round7/prepare_data.py
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
  --config Training/runs/2026-10-17-round7/training-config.yaml \
  --model .context/cleanup-model/base --data .context/cleanup-round7/data \
  --iters 200 --max-seq-length 512 \
  --resume-adapter-file .context/cleanup-round4/selected-adapters/adapters.safetensors \
  --adapter-path .context/cleanup-round7/adapters
```

Resolved arguments are in `training-arguments.json`. Optimizer state resets when
resuming; all other settings match round six. Peak MLX memory was 15.089 GB.
Checkpoint selection was fixed before training: lowest validation loss, including
the starting adapter, with ties favoring fewer steps. Losses were 0.042 at the
start, 0.037 after 100 steps, and 0.030 after 200. Step 200 was selected before
inference. `checkpoint-selection.json` and `training-metrics.txt` preserve evidence.

Place step 200's weights as `adapters.safetensors` alongside `adapter_config.json`
in `.context/cleanup-round7/selected-adapters`. Fuse against the pinned base using
the recipe in `../../README.md`, then quantize 4-bit affine with group size 64.
Preserve the pinned tokenizer files, chat template, and license in both exports.
`candidate-4bit-artifact.json` records export hashes.

## Measured output

| Exact output | Round four | Narrow round six | Balanced round seven |
| --- | ---: | ---: | ---: |
| Fixed training sample, Python | 17/24 | 24/24 | 23/24 |
| Gold, Swift | 6/12 | 6/12 | 5/12 |
| Original holdout, Swift | 5/8 | 5/8 | 5/8 |
| Round-two holdout, Swift | 8/12 | 9/12 | 10/12 |
| Round-three holdout, Swift | 2/8 | 4/8 | 4/8 |
| Round-six holdout, Swift | 4/12 | 7/12 | 8/12 |

All columns use 4-bit exports. The original 40 non-adversarial development cases
score 21/40, 24/40, and 24/40 respectively. Including the twelve round-six cases
makes those totals 25/52, 31/52, and 32/52. These totals are exact output counts,
not a combined quality metric. Separate dimensions and transition IDs are in
`baseline-comparison.json` and `focused-comparison.json`.

All seven targeted training failures are fixed. One previously passing training
control (`candidate-repetition-008`) regresses, giving 23/24 rather than 24/24.
On the 52 non-adversarial development cases there are nine exact improvements and
two regressions against round four. Against the narrow model there are three
improvements and two regressions. In particular:

- The narrow model's `round2-correction-013` regression is fixed.
- `gold-009` still generates invalid trailing-filler spans and falls back.
- `round3-filler-013` still misses initial capitalization after removing filler.
- `gold-006` regresses against round six by capitalizing a sentence continuation.
- `round6-unseen-007` regresses against round six by omitting the vocabulary edit.

Gold context-fit remains 11/12, versus 12/12 for round six. Gold meaning-preservation
checks are 8/12 versus 9/12 for round four and 7/12 for round six. The broader
metrics prevent treating the aggregate exact-output gain as an unconditional win.

The historical strict adversarial fallback count is 6/11, versus 5/11 for round
four and 10/11 for round six. All five accepted plans were reviewed: they only
capitalize the initial word and/or add a period; existing control characters and
the checksum are preserved. See `adversarial-review.json`. This metric counts safe
accepted edits as failures, so fallback frequency alone is not a safety score.

## Evaluation and limitations

Swift evaluated the concatenation of the existing 51-case fixture file and
`../2026-10-17-round6/unseen.jsonl`, using `CleanupEvaluation` with the selected
4-bit model. All 63 cases completed and the process exited 0. `compare.py` checks
exact fixture coverage and computes both reference comparisons. `evaluate_fit.py`
reproduces the 24-case Python diagnostic against round five's saved baseline.
Both scripts refuse to overwrite their prediction/report outputs.

The twelve round-six cases were unseen when authored last round; they are now
exposed development data, not a fresh generalization test. No release-quality claim
follows from these small synthetic sets. Debug M3 Pro timings use 128 output tokens
and a diagnostic 30-second deadline; they do not replace the physical 8 GB M1 test.
All 18 tooling tests pass and `git diff --check` passes.

## Decision

Retain round seven as an experimental checkpoint with better validation loss and
aggregate coverage, not as a release model. Reweighting helps the seven targeted
errors but does not yet deliver consistently correct edit plans. Further work
needs broader coverage of span boundaries, context-sensitive capitalization, and
vocabulary edits, plus an independent evaluation set. Another small reweighting
run alone would not establish launch readiness. Model quality and physical-M1
performance qualification remain outstanding.
