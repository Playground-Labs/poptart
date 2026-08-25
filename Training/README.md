# Cleanup model training

This is a clean-room, reproducible recipe for Poptart's task-specific Cleanup model. Inputs are limited to manually authored synthetic examples committed here or redistributable public sources with an individual provenance record. User Dictations, Target Context, Personal Vocabulary, history, audio, clipboard contents, application content, logs, telemetry, support data, and private operational data are prohibited.

The checked-in corpus is `CC0-1.0`, authored for Poptart, and contains invented names and applications only. Adding a source requires its stable URL, immutable revision, license, author, and redistribution rationale in every JSONL record. The verifier rejects unknown provenance kinds, missing licenses, and fields associated with private product data.

## Reproduce

1. Create a fresh Python 3.12 environment and install `requirements.txt` with hashes added by the release operator's locked environment export.
2. Obtain `Qwen/Qwen3.5-0.8B` at revision `2fc06364715b967f1860aea9cf38778875588b17` under its Apache-2.0 license and place it at the local path in `config/lora.yaml`. Network access is an explicit preparation step, never part of Poptart.
3. Run `python3 Training/prepare_corpus.py`; the script deterministically validates provenance and creates MLX chat JSONL splits.
4. Run `mlx_lm.lora --config Training/config/lora.yaml`.
5. Fuse against the same pinned base, then quantize with `mlx_lm.convert --q-bits 4 --q-group-size 64 --q-mode affine`.
6. Run the exact production prompt/tokenizer/artifact evaluation and physical 8 GB M1 benchmark. Only the release script may populate hashes and measurements.

The repository currently contains no trained weights and makes no quality or latency claim.
