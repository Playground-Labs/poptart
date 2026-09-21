# Cleanup model training

This directory contains the clean-room recipe for Poptart's task-specific Cleanup model. Inputs
are limited to manually authored synthetic examples committed here or redistributable public
sources with an individual provenance record. User dictations, target context, personal
vocabulary, history, audio, clipboard contents, application content, logs, telemetry, support
data, and other private operational data are prohibited.

The checked-in corpus is CC0-1.0, authored for Poptart, and uses invented names and applications.
`prepare_corpus.py` rejects unknown provenance, missing licenses, duplicate utterances, direct
evaluation leakage, invalid plans, and plans whose applied result differs from the labeled clean
text.

## Training target

The model emits a compact Cleanup Edit Plan followed by `<END_PLAN>`, never a rewritten
transcript:

```json
{"v":1,"e":[{"s":0,"e":1,"r":"","c":"filler"},{"s":6,"e":6,"r":".","c":"punctuation"}]}<END_PLAN>
```

Training uses the same system instruction and byte-counted untrusted-data payload as production.
Only the assistant plan contributes loss. Each record in `data/corpus.jsonl` contains:

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique corpus and fixture identifier. |
| `provenance` | yes | Authored-synthetic source, author, license, and repository source. |
| `split` | yes | `train`, `valid`, or `test`. |
| `raw` / `clean` | yes | Input transcript and expected text after applying the plan. |
| `editPlan` | yes | Compact wire-format Cleanup Edit Plan. |
| `vocabularyTerms` | no | Personal vocabulary entries used by the example. |
| `targetContext` | no | Application and text-around-cursor context. |
| `reservedEdits` | no | Deterministic Explicit Corrections, which the model may not author. |

The current corpus has 1,088 records: 1,024 train, 32 validation, and 32 test.

## Reproduce

Training requires Apple Silicon, macOS 26, Python 3.12, a local model, and the pinned package
lock. Model download is an explicit preparation operation; training and the app run offline.

```sh
uv venv --python 3.12 .build/training-venv
uv pip sync --python .build/training-venv/bin/python \
  --require-hashes Training/requirements-macos26-arm64.lock
uv pip check --python .build/training-venv/bin/python
python3 Training/prepare_corpus.py --check
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora-2b.yaml
```

Place the four-bit affine/group-64 conversion of `Qwen/Qwen3.5-2B` revision
`15852e8c16360a2fea060d615a32b45270f8a8fc` at the local path named by
`config/lora-2b.yaml`. `train.py` disables remote tokenizer code and Hub access, validates prompt
masking and sequence lengths, and refuses to overwrite an adapter directory.

Keep the four-bit `base/` and F32 `adapters/` separate when packaging a candidate. Re-fusing the
adapter into four-bit weights caused measured accuracy loss. Trained weights remain gitignored
under `Models/Artifacts`; release metadata may only be populated by the release tooling after
evaluation.

## Selected candidate and evidence

ADR 0054 selects Qwen 3.5 2B with the separate F32 adapter identified in the retained
[candidate decision](experiments/practical-candidate-decision-2026-09-18.json). Across observed
development and regression suites it achieved:

| Measure | Result |
| --- | ---: |
| Exact Cleanup Edit Plan | 555 / 564 |
| Meaning preservation | 558 / 564 |
| Context fit | 561 / 564 |
| Adversarial and runtime checks | all passed |

The single frozen `release-v2` query achieved 48/48 meaning preservation, 4/4 applicable
vocabulary checks, 22/22 adversarial checks, 70/70 runtime checks, and 38/48 delivered-text exact
matches. The stricter gate did not pass: exact plans were 32/48 and context fit was 44/48. See the
[release result](experiments/practical-candidate-release-v2-2026-09-18.json) and its two frozen
plans for the full record.

Known residuals are five unwanted vocabulary substitutions among 128 focused physical-object
cases, one missed capitalization/punctuation cleanup, and one safe raw fallback. These are
post-MVP iteration work; no further holdout-driven training or threshold change is planned.

Only the compact final decision, offline check, frozen plans, and release result are committed.
Intermediate training logs, repeated predictions, rejected candidates, and mutable local
artifacts are intentionally excluded from review. The decision record retains the omitted source
result's path and SHA-256 so an archived copy can be authenticated.

Physical 8 GB M1 evidence cannot be collected on the available hardware. The M5 Pro benchmark,
signed Model Pack capture, signing, notarization, and distribution smoke tests are separate
release evidence.
