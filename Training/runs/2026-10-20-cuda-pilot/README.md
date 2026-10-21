# RTX 5090 CUDA pilot

The exact Qwen3.5-0.8B LoRA pipeline runs on NVIDIA with CUDA graphs disabled,
but this pilot did not demonstrate a speed advantage over the M3 Pro. Do not
extend this configuration into a longer training run on the assumption it is faster.

| Configuration | Result |
| --- | --- |
| Default CUDA graph cache (400) | Failed after 245 seconds with cache thrashing |
| Cache increased to 2048 | Stopped after 159 seconds without a ten-step report |
| `MLX_USE_CUDA_GRAPHS=0` | Completed 20 steps in 129 seconds |

The successful run reported 0.118 iterations/sec for the first interval and
0.309 for the second, versus roughly 0.35–0.45 in earlier local full-pass reports.
This is a short exploratory comparison, not a controlled hardware ranking: CUDA
kernel caches were warmed by earlier attempts, validation was reduced to one
batch, and transitive dependency versions differ (see `packages.txt`). It does
not establish that a 5090 is inherently slower or that another CUDA framework
would perform the same. No additional quality-training run was launched.

MLX reported 14.992 GB peak memory. One-second NVIDIA samples are also retained;
they measure driver-reported usage, not the same quantity as MLX memory accounting.
The one-batch validation losses are not quality qualification.

The adapter was downloaded and its SHA256 matched the remote file:
`ea49f802544c5523c4ed80e735aa11644c60dae3b0985d5f9204c95652a55269`.
Weights stay under `.context/cleanup-cuda-pilot/`, outside Git. The existing
quality-selected model is unchanged. No release metadata was populated.

`protocol.json` records original inputs. `run-*.sh` records each remote command;
`summary.json`, process statuses, raw training logs, packages, and GPU samples
record outcomes. The scripts assume the bundle is staged on the authorized host
and fresh output directories. Model/library pins match the local experiment.

A framework migration would require a separate throughput and numerical-parity
check, adapter conversion, and native Swift evaluation. It is not an immediate
launch shortcut. Recognition Core ML qualification, app/privacy checks, signing,
and the physical 8 GB M1 deadline cannot be replaced by this NVIDIA pilot.

The Pod was idle after completion. The user was told to stop it; SSH access does
not establish that Runpod billing has stopped.

The downloaded adapter fused and exported to affine 4-bit successfully on the Mac.
The real Swift model shutdown regression passed with three clean process exits.
This verifies basic transfer/runtime compatibility, not cleanup quality. All 20
Python tooling tests and `git diff --check` passed.
