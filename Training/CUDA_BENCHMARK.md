# Optional CUDA throughput pilot

No cloud resource is provisioned by this script. It has not yet run on NVIDIA hardware.
For the speed-first pilot, use one RTX 5090 (32 GB), subject to availability and price.
Runpod listed $1.19/hour on 2026-10-18, plus storage. A 4090 is a fallback option. A $5 pilot budget is a
reasonable ceiling to test compatibility and throughput, not a measured cost estimate.

Use a Linux x86-64 host with NVIDIA driver 580 or newer, Ubuntu 22.04 or newer,
a CUDA 13 development template, Python 3.12,
and an isolated virtual environment:

```sh
python -m pip install 'mlx[cuda13]==0.32.3' 'mlx-lm==0.31.3'
```

Copy this repository's training scripts and generated synthetic data, the local base
model (Qwen/Qwen3.5-0.8B revision 2fc06364715b967f1860aea9cf38778875588b17), and
`.context/cleanup-round8/adapters/0000200_adapters.safetensors` to the host. These
ignored artifacts are not included by cloning the repository. Preserve the base
model tokenizer and chat template. No user recordings or real transcripts are needed.

From the repository root, with that virtual environment active:

```sh
Training/benchmark_cuda.sh /path/to/base /path/to/0000200_adapters.safetensors /path/to/new-probe
```

The script checks the actual CUDA backend, records hardware/packages, and runs only
20 steps with the existing LoRA configuration. Inspect `training.log`; compare the
second ten-step `It/sec` report against roughly 0.35–0.45 iterations/sec on this M3 Pro.
The first interval includes warmup. Setup, downloads, validation and export time are
additional; this short probe is not a complete cost benchmark. If it fails, inspect
the log before paying for longer runs. The package's CUDA support does not guarantee
this exact model's performance or numerical agreement.

Only extend the run if measured throughput justifies it. Stop the pod promptly after
collecting artifacts and inspect retained storage charges. A $5 budget is a user-set
limit, not a spending cap implemented by this script. Any resulting model still needs
4-bit export, exact-output selection through Swift, and the physical 8 GB M1 benchmark.
The probe's adapters must not be treated as qualified training candidates.

Sources: [Runpod pricing](https://www.runpod.io/pricing),
[MLX CUDA support](https://github.com/ml-explore/mlx/discussions/2422).

CUDA 13 driver requirements: [MLX 0.32.3 installation documentation](https://github.com/ml-explore/mlx/blob/v0.32.3/docs/src/install.rst).
