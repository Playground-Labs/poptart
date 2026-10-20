# Full-pass continuation: retain the existing model

A complete 262-step pass through the unchanged training set did not improve the
predeclared primary validation score. Keep the round-eight step-200 adapter and
its `.context/cleanup-round9/step-200/candidate-4bit` export as the preferred
experimental model. Neither new checkpoint is promoted or published.

| Additional steps | Logged validation loss | Exact Swift output | Accepted plans |
| --- | ---: | ---: | ---: |
| 0 (existing model) | 0.034 | 38/47 | 42/47 |
| 131 | 0.031 | 33/47 | 41/47 |
| 262 | 0.028 | 38/47 | 40/47 |

Training and both native evaluation processes exited zero. All inference used
4-bit affine exports (group size 64), the existing Swift Cleanup engine, and the
current control-character guard. The base tokenizer, chat template, and license
were preserved and verified by hash. These are diagnostic M3 Pro results.

## Protocol and evidence

`protocol.json` and `inputs.json` were frozen before training. The highest exact
resolved-output count on the fixed 47 validation records wins; ties prefer fewer
additional steps. Thus the baseline wins without consulting evaluation data.
The baseline predictions were reused from round nine: none of these 47 inputs
contains the non-whitespace control characters affected by the intervening guard.
`score.py` asserts that condition. No new 79-case evaluation was run because no
new checkpoint won; the baseline's post-guard result remains 49/68 non-adversarial
exact outputs, with the detailed adversarial review in the control-guard report.

`coverage.json` exercises the installed MLX batch iterator with tagged synthetic
records: 200 steps cover 200 of 262 positions, and 262 steps cover all 262 once.
It does not reconstruct historical real-example IDs. The continuation uses the
same data, rank-8 LoRA, last 16 layers, batch 1, learning rate 1e-5, seed, prompt
masking, and 512-token limit. `resolved-training-args.json` records the actual
arguments; `training-metrics.txt` records every report and both saved checkpoints.
Peak MLX memory was 16.206 GB. Loss values are rounded diagnostics.

`step-131.jsonl` and `step-262.jsonl` contain all raw native results.
`comparison-*.json` preserves separate quality dimensions and regression IDs;
`ranking.json` records the decision. `artifact-*.json` hashes both exports and
adapters. `verification.json` records completion and input integrity checks.

## Tradeoffs

At step 262, original validation improves 23/29 to 25/29 while expanded validation
falls 15/18 to 13/18. There are four improvements and four regressions. All four
regressions (`round3-vocabulary-012`, `round8-repetition-011`,
`round8-leading_um-012`, `round8-vocabulary-012`) produce invalid span/category
plans rejected to raw fallback. Meaning-preservation passes total 40/47 for both
models; exact-plan matching changes 38/47 to 37/47; context-fit remains 47/47.
The halfway checkpoint has four improvements and nine regressions.

Lower token loss again fails to imply better end-to-end cleanup. Simply adding
training steps is not a demonstrated route to launch quality. These small
synthetic sets have already been exposed during development. The remaining model
errors and unavailable physical 8 GB M1 qualification still prevent release.

## Reproduction

With the pinned environment, base model, and starting adapter present, run:

```sh
.context/cleanup-model/venv/bin/python -u -m mlx_lm lora \
  --config Training/runs/2026-10-18-full-epoch/training-config.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 262 --max-seq-length 512 \
  --resume-adapter-file .context/cleanup-round8/adapters/0000200_adapters.safetensors \
  --adapter-path .context/cleanup-round10/adapters
```

For each saved step, create `.context/cleanup-round10/step-{131,262}/adapters`,
copy its checkpoint there as `adapters.safetensors`, and copy `adapter_config.json`.
Use fresh export and prediction paths before running `evaluate_checkpoints.sh`
and `score.py`; the scorer refuses to overwrite reports. `compare_evaluation.py`
is available only if a future validation-selected candidate warrants the separate
evaluation; it was not used in this experiment.

The separate [CUDA pilot guide](../../CUDA_BENCHMARK.md) supplies a bounded
20-step throughput test for an existing NVIDIA host. No cloud resource was rented;
CUDA compatibility and speedup remain unmeasured. All 20 Python tooling tests pass,
the new shell scripts pass syntax checks, and `git diff --check` passes.
