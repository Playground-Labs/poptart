# Third Cleanup candidate

Round two improved its new holdout but regressed filler capitalization and
vocabulary joining. This experiment adds 40 training and 8 validation examples
focused on those failures, redundant capitalization of `I`, and commands with
trailing fillers. The corpus now has 172 training and 29 validation examples;
all previous records are unchanged. Eight additional holdout cases were frozen
before training and are saved as `holdout.jsonl`.

This is development tuning informed by previous evaluation results, not an
independent release-quality evaluation. New holdouts share the authored task
families. More representative unseen data is still needed.

## Reproduction

Use the Python environment from the first pilot and pinned base revision
`2fc06364715b967f1860aea9cf38778875588b17`. Train fresh from that base:

```sh
python3 Training/prepare_corpus.py
.context/cleanup-model/venv/bin/python -m mlx_lm lora \
  --config Training/config/lora.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 200 --max-seq-length 512 \
  --adapter-path .context/cleanup-round3/adapters
```

Select the lower validation loss at step 100 or 200, using 100 for a tie, before
evaluating either checkpoint. `training-arguments.json` records the resolved
settings; `inputs.json` records source/data hashes. All training prefixes match
non-thinking inference, and the maximum sequence length remains 408 tokens.

Fuse and quantize the selected checkpoint with the first pilot's commands,
substituting `.context/cleanup-round3` paths. Preserve the base tokenizer files,
chat template, and license. `artifact.json` records the exported file hashes.
Weights remain local and are not published or included in release metadata.

Run both round two and round three through `CleanupEvaluation` on the same 51
cases: 12 gold, 11 adversarial, 8 original holdout, 12 round-two holdout, and 8 new
holdout cases. The debug Swift runtime uses the production engine and validator,
128 output tokens, an 8,192 input-token limit, and a diagnostic 30-second deadline
on the 36 GB M3 Pro. These times cannot satisfy the M1 launch benchmark.

Reproduce the comparison from saved predictions with:

```sh
python3 Training/compare_swift_candidates.py \
  Training/runs/2026-10-17-round3/baseline-predictions.jsonl \
  Training/runs/2026-10-17-round3/candidate-predictions.jsonl \
  --extra-holdout Training/data/round3-holdout.jsonl \
  --output .context/cleanup-round3/comparison-recheck.json
```

The comparison keeps every existing criterion unchanged. Exact output can include
raw fallback; accepted-plan counts and raw generations must also be inspected.
The strict adversarial metric requires fallback, even for otherwise harmless
edits. Its score is not equivalent to a count of harmful outputs. The separate
meaning-preservation and context-fit metrics are heuristics. See the previous
report for the legacy `gold-001` correction-reservation mismatch.


## Results and decision

Step 200 was selected before evaluation: validation loss 0.059, versus 0.074
at step 100. The round-two baseline, round-three 4-bit export, and round-three
unquantized fused export each completed all 51 cases and exited zero.

| Measure | Round two, 4-bit | Round three, 4-bit | Round three, unquantized |
| --- | ---: | ---: | ---: |
| Exact gold output | 6/12 | 5/12 | 5/12 |
| Exact original holdout output | 4/8 | 3/8 | 6/8 |
| Exact round-two holdout output | 9/12 | 6/12 | 8/12 |
| Exact new holdout output | 0/8 | 2/8 | 2/8 |
| Strict adversarial fallback | 4/11 | 7/11 | 3/11 |

**Reject both round-three exports for release.** The 4-bit candidate fixes
`gold-002` and the two new leading-filler cases, but loses repetition, question,
and context-continuation behavior. Gold meaning-preservation drops from 9/12 to
8/12 and context-fit from 12/12 to 11/12. Lower validation loss did not produce
better overall inference behavior.

The quantization control uses the same selected checkpoint, pinned tokenizer,
Swift runtime, prompts, and decoding settings, but loads the unquantized fused
weights. `unquantized-artifact.json` records their hashes. It fixes five exact
outputs lost after quantization, with no exact-output regressions on the 40
non-adversarial cases. This is evidence that 4-bit quantization contributes to
quality loss in this checkpoint. It does not explain all the failures:

- Both exports emit redundant `I` to `I` capitalization edits, causing fallback.
- Both fail the two new vocabulary cases with incorrect span positions.
- Both leave trailing fillers in commands and fail to remove some repetitions.
- Both capitalize sentence continuations incorrectly.
- Unquantized output still introduces inappropriate question marks; accepted
  adversarial outputs can retain existing hidden/control characters. The strict
  fallback gate remains failed. More fallbacks caused by malformed plans do not
  establish stronger model safety.

`comparison.json` compares round two against round three at 4-bit.
`quantization-comparison.json` uses round-three 4-bit as `baseline` and the
unquantized export as `candidate`. Each report includes all quality dimensions
and exact-output improvement/regression IDs. All raw predictions are retained.
To reproduce the precision control, run `CleanupEvaluation` with
`.context/cleanup-round3/fused`, then use the same comparison command with the
4-bit and unquantized prediction files.

Next: measure exact plan/output accuracy on a fixed sample of training records
using unquantized weights. If it cannot reproduce learned targets, investigate
training duration/objective before adding more examples. Then test quantization
on the selected model explicitly, rather than assuming export preserves quality.
Any further tuning needs additional independent evaluation before release claims.

Verification: 18 Python tooling tests pass, including all 209 corpus records,
all separate holdouts, split separation, and comparison failure checks. All old
161 corpus records remain byte-for-byte unchanged as a prefix. New holdout
prompts match production Swift byte-for-byte. No production runtime code or
release metadata changed in this round. The M1 qualification is outstanding.
