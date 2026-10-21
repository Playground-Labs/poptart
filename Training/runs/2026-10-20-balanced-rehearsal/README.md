# Balanced rehearsal: validation gain, historical retention failure

Decision: **reject the new checkpoints and retain round-nine step 200**. This
completed the single run proposed in [the frozen experiment](../../../docs/cleanup-next-experiment.md).
No app/runtime, canonical corpus, production metadata, or ADR changes were made.

| Model | Existing validation /47 | Added validation /8 | Total /55 | Existing correct cases lost |
| --- | ---: | ---: | ---: | ---: |
| Retained baseline | 38 | 4 | 42 | 0 |
| Step 40 | 37 | 6 | 43 | 4 |
| Step 80 | 44 | 7 | 51 | 0 |

Step 80 passed validation selection, so only it and the baseline were evaluated
on the historical 79 cases (68 ordinary, 11 adversarial) and 16 fresh cases.

| Post-selection set | Baseline | Step 80 | Retention result |
| --- | ---: | ---: | --- |
| Historical exact output | 49/68 | 48/68 | Five improved, six previously correct regressed |
| Fresh exact output | 8/16 | 13/16 | Five improved, no previously correct regressed |
| Adversarial outputs/outcomes | 11 cases | All unchanged | Six fallbacks; five accepted capitalization/punctuation plans |

The six historical regressions were a cursor-context capitalization error
(`gold-006`), three accepted periods inserted before the final word
(`round2-statement-013`, `round6-unseen-001`, `round6-unseen-002`), and two
invalid deletion plans rejected to raw (`round8-independent-002`,
`round8-independent-007`). The latter are filler and repetition cases.
All changed outputs and all 11 adversarial cases were reviewed in
`changed-outputs.json`; the decision is recorded in `decision.json`.
An unchanged adversarial output does not prove general safety.

## What changed and what ran

Only the selection of 32 rehearsal records changed from the rejected targeted
run: 16 vocabulary, four internal filler, four repetition, two empty plans,
two questions, two reserved corrections, and two cursor-context records.
The other 48 training records, all 55 validation inputs, starting adapter,
80-step budget, seed, and optimizer settings were unchanged. The resolved
configuration differs only in the config/data/output paths. Total training
coverage is in `coverage.json`; selected IDs are in `rehearsal.json`.

Training completed with exit 0, batch size 1, learning rate 5e-6, rank 8,
scale 20, last 16 layers, prompt masking, and a 512-token sequence limit.
Peak reported memory was 15.061 GB. Validation loss was 0.034 initially,
0.027 at step 40, and 0.022 at step 80; loss was not a selection criterion.

Input data and the selection protocol were saved before training. The initial
token-length check mistakenly counted the two keys in a tokenizer result;
it was corrected during startup using `return_dict=False`. Actual maximum
lengths were 407 training / 408 validation, within the limit. No input or
selection rule changed. `token-lengths.json` records this sequencing exception.

Both checkpoints were fused and exported as affine 4-bit/group-64 models.
Tokenizer, template and license hashes match the base exactly. Native Swift
CleanupEvaluation produced complete 55-case predictions for three models and
95-case predictions for baseline/step 80, all processes exiting 0. The fresh
16 were used only after validation selected step 80 and are now exposed
experimental evidence, not an untouched future holdout.

The scorer was checked against the previous rejected predictions and synthetic
positive/negative controls. Post-selection controls require fresh improvement
and reject loss of a previously correct historical case. Existing Python tooling
and release tests passed (26 total), and both evaluation scripts passed shell
syntax checks. `verification.json` records the checks; hashes and predictions
are retained alongside this report.

## Reproduction and next decision

`prepare.py` writes a fresh `.context/cleanup-balanced` directory; it refuses an
existing destination. The training invocation is the one in the proposal, with
`--config Training/runs/2026-10-20-balanced-rehearsal/training-config.yaml`.
`evaluate.sh`, `score.py`, `evaluate_selected.sh`, and `score_selected.py` record
the evaluation procedure. Existing prediction files deliberately prevent reruns
from overwriting evidence; use new paths for reproduction.

Rejected weights remain locally at `.context/cleanup-balanced/step-{40,80}/candidate-4bit`
and `.context/cleanup-balanced/adapters`; `artifact-*.json` records their hashes.
The retained model remains `.context/cleanup-round9/step-200/candidate-4bit`.
Large model weights are not committed to Git.

Balanced rehearsal helped validation vocabulary/repetition and generalized some
trailing-filler behavior, but did not preserve broad behavior. This is evidence
against repeating this small continuation recipe, not proof that Qwen or the
edit-plan architecture cannot work. Stop this recipe. A next bounded comparison
should investigate span positioning and context handling before spending more
on training; define that protocol separately rather than retuning against these
now-exposed evaluation cases.

All results are synthetic development evidence on the local Mac with a
30-second diagnostic deadline. They do not qualify release quality, physical
8 GB M1 full-app latency, recognition quality, or signed-build privacy checks.
