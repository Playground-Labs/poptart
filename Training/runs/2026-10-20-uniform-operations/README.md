# Uniform-operation discriminator: rejected

The 100-step uniform-operation candidate fails the frozen retention gate. Keep
the retained round9/step200 model; it is still experimental and not release
qualified. No app schema, production manifest, or selected artifact changed.

| Arm | Exact / 91 | Regressions against retained |
| --- | ---: | ---: |
| Retained baseline (cached) | 61 | — |
| Matched range control (cached) | 71 | 14 |
| Previous hybrid format (reference only) | 29 | 47 |
| Uniform discriminator, 4-bit | 49 | 31 |

The uniform candidate also loses 28 correct range-control outputs. It improves
no targeted group over both controls. The broader historical/fresh evaluation
and native compiler port were conditional on passing this gate, so neither was
triggered. See `comparison.json` for every regression and improvement ID.

## What this run isolates

Every range edit now includes `o:edit`, alongside the existing `o:end` and
`o:delete` operations. This tests whether the previous hybrid format's missing
range edits were caused by mixing operation shapes. Source records, ordering,
user payloads, target semantics, starting adapter, optimizer, seed, 100-step
budget, and runtime match the prior experiment. The format and one system-prompt
example change. Token counts differ, so equal steps do not mean equal compute.

Training uses 100 records, with 67 loss-validation records and 91 evaluation
cases. Controls are exact cached prediction bytes from the prior experiment,
not newly generated observations. `protocol.json` and the input/execution hash
ledgers were frozen before candidate inference. This is an exposed diagnostic
set, not an independent release-quality estimate.

## Validation and artifacts

The diagnostic fused bfloat16 checkpoint scores **53/91**, versus 49/91 after
4-bit export: seven cases are correct only in full precision, three only in
4-bit, and 14 change output or outcome. Quantization affects this checkpoint,
but the unquantized model still underperforms the retained 61/91 baseline.
This is a single-checkpoint observation, not a general estimate of quantization
damage. `diagnostic-comparison.json` records all changed cases.

Unlike the hybrid arm's zero range edits, the 4-bit uniform arm produces 53
range operations in 85 compiled plans: 41 capitalization, six filler, four
vocabulary, and two repetition edits. It also produces 82 end and 18 delete
operations. Compilation is not safety acceptance: six plans fail compilation
and another 11 fail validation, producing 17 raw fallbacks. Full precision
also compiles 85 plans, with 12 total fallbacks. Restoring operation coverage
did not restore reliable cleanup. Counts exclude operations in uncompiled plans.

All 34 Python tooling/compiler tests pass, including 317 canonical target
roundtrips. The 167 matched train/validation targets compile to the same plans
and outputs as before. Scorer controls test improvement, regression, no gain,
and incomplete predictions. Both shell scripts pass syntax checks.

The final adapter, fused bfloat16 model, and affine 4-bit/group64 export are
recorded in `artifact-manifest.json`. Tokenizer, chat template, and license match
the base exactly. Large weights remain local under `.context/cleanup-uniform`;
Git contains code, predictions, logs, and hashes only. No native Swift parity or
physical 8GB M1 qualification is claimed.

Reproduction: use a fresh output directory for `prepare.py`, then `train.sh`
and `export_evaluate.sh`. Scripts refuse existing data/predictions. Run
`test_score.py` for selection checks. The separate
`evaluate_full_precision.py uniform-fp .context/cleanup-uniform/fused` command
uses the same inputs and greedy 128-token decoder. Its protocol was added
during training, before inference; full precision cannot qualify for promotion.

## Stop decision

This completes the predeclared one-variable follow-up. Stop short schema-migration
continuations: neither mixing nor uniformly tagging operations has preserved
the complete cleanup task in this training regime. This does not establish that
the architecture cannot learn it, or that more GPU power would solve it.

The next training effort needs a full-task protocol: comprehensive coverage of
all operation categories, paired contexts with varied phrasing, a fixed training
budget and checkpoint rule, and an untouched evaluation set. Compare against
the retained model and keep the same safety/retention requirements. Freeze that
design before another run; do not keep tuning against these 91 cases or change
the production format based on this rejected experiment.
