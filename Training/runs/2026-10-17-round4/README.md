# Training-fit diagnosis and continuation

The previous unquantized candidate produced only 15/24 exact outputs on a fixed
sample of its own training records. The sample takes index `floor(i*172/24)` for
`i=0..23` from the corpus's training order. All nine failed examples also failed
in Python MLX using the same Swift-generated prompts; one passing control passed.
Loading the base and LoRA adapter separately produced the same outputs as the
fused model on these ten cases. This rules out a Swift-only or fusion-only
explanation for the sampled failures.

`training-sample.jsonl`, `training-baseline.jsonl`, `python-diagnostic.jsonl`, and
`python-unfused-diagnostic.jsonl` preserve that evidence. These are training-fit
diagnostics, not independent quality measurements.

## Continuation

No corpus, prompt, validator, or release criteria changed. The round-three
selected adapter was trained for 200 additional steps, with the same batch size,
learning rate, seed, and 172 training / 29 validation records. The CLI restores
adapter weights but resets optimizer state. Gradient checkpointing was disabled
to trade memory for speed; peak MLX memory was approximately 15.1 GB. Selection
compared the starting adapter with additional steps 100 and 200 using validation
loss only, breaking ties in favor of fewer steps.

The losses were 0.059 at the start, 0.063 at step 100, and 0.041 at step 200. The
last checkpoint was selected before evaluation. Training-sample exact output
improved from 15/24 to 19/24. Remaining training failures include redundant `I`
capitalization and a vocabulary-span error.

Reproduce using the Python environment from the first pilot:

```sh
.context/cleanup-model/venv/bin/python -m mlx_lm lora \
  --config Training/runs/2026-10-17-round4/training-config.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 200 --max-seq-length 512 \
  --resume-adapter-file .context/cleanup-round3/selected-adapters/adapters.safetensors \
  --adapter-path .context/cleanup-round4/adapters
```

`training-arguments.json` records resolved arguments. `inputs.json` records input
and starting-adapter hashes; `checkpoint-selection.json` and `training-metrics.txt`
record selection and training. Fuse the selected adapter using the earlier run's
recipe. Preserve the pinned tokenizer, chat template, and license. Export a
4-bit affine candidate with group size 64, as required by ADR 0039.

All evaluations use the actual Swift Cleanup engine on the same 51 development
cases, with 128 output tokens and a diagnostic 30-second deadline. The debug M3
Pro timings are not release-performance evidence. No weights are published or
entered into release metadata. Local export hashes are recorded in the artifact
JSON files.

## Unquantized results

Compared with the round-three unquantized export:

| Exact output | Before | After |
| --- | ---: | ---: |
| Gold | 5/12 | 6/12 |
| Original holdout | 6/8 | 6/8 |
| Round-two holdout | 8/12 | 9/12 |
| Round-three holdout | 2/8 | 2/8 |

This is 21/40 to 23/40 across the non-adversarial cases. It includes improvements
and regressions, recorded separately in `comparison.json`. The strict adversarial
fallback count changes from 3/11 to 4/11. It is not a count of unsafe edits:
`SPEC.md` prohibits known accepted unsafe edits, whereas the existing harness
counts every accepted adversarial plan as a failure, even harmless capitalization.
The historical metric remains unchanged; raw outputs require separate review.

All these evaluation sets have now informed development. These results do not
establish independent generalization or readiness for release.


## Final 4-bit outcome

The 4-bit export completes all 51 cases and exits zero. It reaches 21/40 exact
non-adversarial outputs, compared with 19/40 for round two and 16/40 for round
three at the same precision and on the same 51-case set. These totals are only a
convenient exact-output count, not a combined score for the four quality dimensions.

| Exact output | Round two 4-bit | Round three 4-bit | Continuation 4-bit |
| --- | ---: | ---: | ---: |
| Gold | 6/12 | 5/12 | 6/12 |
| Original holdout | 4/8 | 3/8 | 5/8 |
| Round-two holdout | 9/12 | 6/12 | 8/12 |
| Round-three holdout | 0/8 | 2/8 | 2/8 |
| Strict adversarial fallback | 4/11 | 7/11 | 5/11 |

`quantized-comparison.json` compares with round three, `round2-comparison.json`
compares with round two, and `export-comparison.json` isolates this checkpoint's
unquantized-to-4-bit change. All retain separate quality dimensions and regression
IDs. The export loses two exact outputs relative to its unquantized version.

The six accepted adversarial outputs were inspected: they only change initial
capitalization and/or add a final period. None follows injected instructions,
mutates the URL/checksum, copies context, or deletes spoken words. The hidden
Unicode case retains the existing character; no new hidden character is introduced.
This is a narrow observation on these fixtures, not proof of general safety. The
unchanged strict fallback metric is still only 5/11.

**Keep this as an experimental candidate; do not ship it.** It improves the
aggregate exact-output count, but has regressions against round two and remains
wrong on nearly half the non-adversarial cases. It still emits redundant no-op
capitalization, misses filler capitalization and repetition, gets vocabulary
spans wrong, and capitalizes a sentence continuation incorrectly. Raw fallback
prevents several bad plans from being applied. No validator rules were relaxed
and no generated plan was repaired to inflate the results.

The diagnosis has narrowed the problem: it is not solely a Swift runtime or
adapter-fusion issue, more training helps, and quantization loses some quality.
Further small batches of narrowly targeted examples are not yet producing a
reliable model. The next training effort should measure exact training-plan fit
alongside loss, preserve balanced context/repetition/vocabulary coverage, and
validate quantized output explicitly. These development sets are already exposed;
release qualification also requires representative unseen evaluation and the
physical 8 GB M1 benchmark.

Verification: all 18 Python tooling tests pass; all requested native model runs
completed with zero exit status; `git diff --check` passes. Weights remain local
at `.context/cleanup-round4/candidate-4bit`; release metadata is unchanged.
