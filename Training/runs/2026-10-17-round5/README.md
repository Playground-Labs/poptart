# Focused prompt experiment

Decision: reject the inference-only prompt change. Keep the production prompt,
training data, validator, and release metadata unchanged.

The round-four 4-bit model was run with the existing system prompt and with one
additional instruction forbidding identity edits, specifically mentioning already
capitalized `I`. Both used the same fixed 24-record training sample and the exact
user prompts previously recorded by Swift. Greedy decoding, 128 output tokens,
nonthinking mode, and the Python validator mirror were identical in both arms.
The complete system prompts are in `report.json`.

Both arms produced 17/24 exact outputs. There were zero exact-output improvements
and zero regressions. Generated plans changed for only `round3-vocabulary-003`,
which still failed validation. The three baseline identity-edit failures remained.
All raw generations and validation errors are retained in `baseline.jsonl` and
`candidate.jsonl`. This is a training-set diagnostic, not an unseen evaluation.

The round-four 19/24 training result was unquantized. This experiment uses its
4-bit export; comparing 17/24 against 19/24 is not a prompt-effect measurement.
The paired comparison here is 17/24 against 17/24. No new Swift run was warranted
because the candidate failed the prerequisite improvement gate. The model's most
recent production-runtime evaluation remains 21/40 exact non-adversarial outputs.
It is not release-ready, and the physical 8 GB M1 benchmark remains outstanding.

Reproduce from the repository root, moving the existing output files first (the
script deliberately refuses to overwrite predictions):

```sh
.context/cleanup-model/venv/bin/python -u \
  Training/runs/2026-10-17-round5/evaluate_prompt.py
```

The local model is `.context/cleanup-round4/candidate-4bit`; its export manifest
is linked from `inputs.json`. No additional training or model export occurred.

## Next experiment boundary

Stop inference-prompt tuning for this hypothesis. Existing evidence points to
learned edit-plan errors: identity edits, invalid punctuation spans, and malformed
JSON still occur on training examples. Before another full training run, use a
small fixed diagnostic set containing these failures and passing controls to test
whether a targeted training change can learn the valid plans. Require improvement
without losing the controls, then evaluate the exported 4-bit model through Swift
on the existing development cases and a newly authored unseen set. Do not relax
the validator or promote a model based on training loss alone.
