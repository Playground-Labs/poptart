# Cleanup model training

This is a clean-room, reproducible recipe for Poptart's task-specific Cleanup model. Inputs are limited to manually authored synthetic examples committed here or redistributable public sources with an individual provenance record. User Dictations, Target Context, Personal Vocabulary, history, audio, clipboard contents, application content, logs, telemetry, support data, and private operational data are prohibited.

The checked-in corpus is `CC0-1.0`, authored for Poptart, and contains invented names and applications only. Adding a source requires its stable URL, immutable revision, license, author, and redistribution rationale in every JSONL record. The verifier rejects unknown provenance kinds, missing licenses, and fields associated with private product data.

## The training target is a Cleanup Edit Plan

The model decodes only the Cleanup Edit Plan schema, so that is what it is trained to emit — never a rewritten transcript. Each generated assistant message is the compact plan document followed by the `<END_PLAN>` stop marker, exactly what `BoundedEditPlanParser` accepts:

```
{"v":1,"e":[{"s":0,"e":1,"r":"","c":"filler"},{"s":6,"e":6,"r":".","c":"punctuation"}]}<END_PLAN>
```

The system message is `CleanupPrompt.qwen35SystemInstruction` and the user message is the byte-counted untrusted-data payload `CleanupPrompt.build` produces, so training inputs have the same shape as inference inputs. `mask_prompt: true` in `config/lora.yaml` means only the plan contributes loss.

### Corpus records

`data/corpus.jsonl`, one JSON object per line:

| Field             | Required | Meaning                                                                          |
| ----------------- | -------- | -------------------------------------------------------------------------------- |
| `id`              | yes      | Unique across every corpus and fixture file.                                       |
| `provenance`      | yes      | Exactly `{"kind":"authoredSynthetic","author":"Playground Labs","license":"CC0-1.0","source":"repository"}`. |
| `split`           | yes      | `train`, `valid` or `test`.                                                        |
| `raw`             | yes      | The Raw Transcript.                                                                |
| `clean`           | yes      | The text the plan must reproduce. It is a check, never a training target.           |
| `editPlan`        | yes      | The Cleanup Edit Plan to decode, in the compact wire schema.                        |
| `vocabularyTerms` | no       | Personal vocabulary entries in play for this record. Defaults to `[]`.              |
| `targetContext`   | no       | `{"applicationIdentifier","applicationCategory","textBeforeCursor","textAfterCursor","selectedText"}`. Defaults to an empty text-editor context. |
| `reservedEdits`   | no       | Deterministic Explicit Corrections. Defaults to `[]`; a model-authored `correction` is rejected. |

Before writing anything, `prepare_corpus.py` decodes each plan through the Python mirror of the runtime parser, checks it against **every** rule in `CleanupEditPlanValidator.validate`, applies it to `raw`, and aborts the whole build unless the result equals `clean`. Fixture and corpus plans are validated by the same mirror, `Evals/editplan.py`.

Training the model on a plan the runtime would reject teaches it to produce fallbacks, so the change budget matters when authoring: a record's edits may change at most `max(8, ceil(characterCount * 0.35))` characters, counting `max(sourceCharacters, replacementCharacters)` per edit. A multi-span vocabulary correction is expensive, so the Dictation carrying it has to be long enough to pay for it.

## Reproduce

1. Create a fresh Python 3.12 environment and install `requirements.txt` with hashes added by the release operator's locked environment export.
2. Obtain `Qwen/Qwen3.5-0.8B` at revision `2fc06364715b967f1860aea9cf38778875588b17` under its Apache-2.0 license and place it at the local path in `config/lora.yaml`. Network access is an explicit preparation step, never part of Poptart.
3. Run `python3 Training/prepare_corpus.py`; the script deterministically validates provenance, proves every Cleanup Edit Plan reproduces its clean text, and creates MLX chat JSONL splits.
4. Run `mlx_lm.lora --config Training/config/lora.yaml`.
5. Fuse against the same pinned base, then quantize with `mlx_lm.convert --q-bits 4 --q-group-size 64 --q-mode affine`.
6. Run the exact production prompt/tokenizer/artifact evaluation and physical 8 GB M1 benchmark. Only the release script may populate hashes and measurements.

The repository currently contains no trained weights and makes no quality or latency claim.

## Initial local candidate

The first pilot used 89 authored synthetic records: 72 training, 9 validation,
8 test. The additions cover questions, punctuation, filler, accidental repetition,
invented vocabulary, sentence continuation, and deliberate no-op cases. These are
small development sets, not sufficient coverage for a release quality claim. The
12 gold and 11 adversarial evaluation fixtures remain separate from training.

`evaluate_candidate.py` generates real local-model predictions, saves the raw
outputs and rejection reasons, and scores them using the existing Python edit-plan
mirror. It uses the production system/user prompt, non-thinking chat template,
greedy decoding, 128 output tokens, and the stop marker. It does **not** run the
Swift adapter, enforce a completion deadline, or certify release performance.
It refuses to reuse an output directory, so stock and candidate evidence remain
separate. `report.json` includes model/input hashes and runtime versions.

A reproducible first experiment (run from the repository root):

```sh
uv venv --python 3.12 .context/cleanup-model/venv
uv pip install --python .context/cleanup-model/venv/bin/python \
  -r Training/runs/2026-10-05/requirements.txt
```

Explicitly download `Qwen/Qwen3.5-0.8B` at the revision above into
`.context/cleanup-model/base` with `huggingface_hub.snapshot_download`. Keep its
license and tokenizer files. Then:

```sh
python3 Training/prepare_corpus.py
.context/cleanup-model/venv/bin/python -m mlx_lm lora \
  --config Training/config/lora.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 100 --max-seq-length 512 \
  --adapter-path .context/cleanup-model/aligned-adapters
.context/cleanup-model/venv/bin/python -m mlx_lm fuse \
  --model .context/cleanup-model/base \
  --adapter-path .context/cleanup-model/aligned-adapters \
  --save-path .context/cleanup-model/fused
.context/cleanup-model/venv/bin/python -m mlx_lm convert \
  --hf-path .context/cleanup-model/fused \
  --mlx-path .context/cleanup-model/candidate-4bit \
  -q --q-bits 4 --q-group-size 64 --q-mode affine
cp .context/cleanup-model/base/tokenizer*.json \
  .context/cleanup-model/base/chat_template.jinja \
  .context/cleanup-model/base/LICENSE .context/cleanup-model/candidate-4bit/
.context/cleanup-model/venv/bin/python Training/evaluate_candidate.py \
  --model .context/cleanup-model/candidate-4bit \
  --output .context/cleanup-model/candidate-evaluation
```

Declare checkpoint selection using resolved validation outputs before inspecting
test results. Review separate quality dimensions and regressions alongside exact
outputs; token loss alone misranked the round-eight checkpoints (see round nine
below). The historical commands above use the final checkpoint. Record any earlier selection in the
run report and use a separate adapter directory containing that checkpoint and
its `adapter_config.json`.

For a fair quantized baseline, convert the pinned base with the same options to
`.context/cleanup-model/stock-4bit` and evaluate it into a different directory.
Preserve the pinned tokenizer JSON, embedded chat template, and license in both
exports. Transformers re-saving otherwise moves the template out of
`tokenizer_config.json`; keeping the original files avoids depending on a different
tokenizer serialization format in Swift.
The 512-token training limit is an experiment setting, not a shipping Cleanup
input ceiling; verify tokenized examples fit before rerunning after corpus edits.
The initial run checked every training prefix against non-thinking inference and
found a maximum full training sequence length of 407 tokens.

The dated requirements file records the actual Python environment (versions, not
package hashes). A release environment still needs a hash-locked dependency export.
The upstream LoRA CLI currently sets `trust_remote_code=True` internally despite
our YAML field; use only the inspected pinned local snapshot, which has no custom
Python files or auto-map entries. The candidate evaluator explicitly disables it.

The existing adversarial score demands fallback for every adversarial fixture.
A valid conservative/no-op plan also fails that score, so inspect actual outputs
and rejection reasons before calling a score change a safety regression. Do not
silently loosen the release gates to make a candidate pass.

Results and artifact hashes for the first pilot are in
[runs/2026-10-05](runs/2026-10-05/README.md). The candidate is explicitly rejected
for release; that report records the remaining model errors and URL guard fix.


## Swift runtime evaluation

With Xcode and its Metal toolchain installed, run the local candidate through the
actual Cleanup engine. No model download occurs in this executable. Use a new
output path on every run; input records must carry repository-authored synthetic
provenance. Example for the gold fixtures:

```sh
swift run --package-path Packages/Cleanup CleanupEvaluation \
  "$PWD/.context/cleanup-model/candidate-4bit" \
  "$PWD/Evals/fixtures/gold.jsonl" \
  "$PWD/.context/cleanup-model/swift-gold.jsonl"
python3 Training/test_swift_runtime.py .context/cleanup-model/candidate-4bit
```

To evaluate all development cases, concatenate the gold and adversarial JSONL
files with the `split == "test"` records from `Training/data/corpus.jsonl` into a
new fixture file. The runner records generated plans, actual prompts, outcomes,
and elapsed time. It uses a diagnostic 30-second deadline, 8,192 input-token
ceiling, and the production 128-token output budget. Results are explicitly
`releaseQualified=false`; debug timings do not satisfy launch latency gates.
The subprocess regression checks that early stopping also exits cleanly, since
the original shutdown crash happened after the result file was written.


## Second local candidate

The second experiment used 132 training, 21 validation, and the original 8 test records.
The 72 additions cover statement/question distinctions, filler positions,
repetition, deterministic correction spans, and text that should remain unchanged.
`data/round2-holdout.jsonl` contains 12 separately frozen cases, excluded from both
training and checkpoint selection. These development sets are small and authored
from the same task categories; they do not establish broad generalization.

This experiment starts fresh from the pinned base, uses 200 steps and the same
LoRA settings, and selects the lower validation loss at step 100 or 200 (ties use
100) before inference on evaluation sets. Use new adapter/export directories.
Fuse the selected checkpoint by placing it as `adapters.safetensors` alongside
its `adapter_config.json`; preserve the original tokenizer files as above.

Concatenate the gold, adversarial, original test, and round-two holdout records
into one 43-case fixture file. Run `CleanupEvaluation` for both exported candidates
with that file, then compare the saved predictions:

```sh
python3 Training/compare_swift_candidates.py \
  Training/runs/2026-10-17/baseline-predictions.jsonl \
  Training/runs/2026-10-17/candidate-predictions.jsonl \
  --output .context/cleanup-round2/comparison-recheck.json
```

The comparison reports all existing quality dimensions, exact outputs, accepted
plans, and the IDs of exact-output improvements and regressions. It rejects
missing, extra, or duplicate predictions. Raw fallbacks count as exact when the
fixture already needs no changes, so exact-output counts alone are insufficient.


## Third local candidate

The corpus now has 172 training and 29 validation records, with all previous
records unchanged. `data/round3-holdout.jsonl` adds eight frozen cases outside the
training and validation splits. This round targets the filler capitalization,
vocabulary, redundant-edit, and command-punctuation failures from round two.
See [the run report](runs/2026-10-17-round3/README.md) for training settings,
artifact hashes, and the full comparison. Use `--extra-holdout` with the comparison
script to include this file; omitting it preserves the earlier 43-case report.


## Training-fit diagnosis and continuation

The next experiment kept the corpus fixed, measured exact outputs on a fixed
24-record training sample, checked Python/Swift and fused/unfused behavior, and
continued the round-three adapter for 200 more steps. Training-sample accuracy
rose from 15/24 to 19/24. The selected 4-bit export reached 21/40 exact outputs on
the existing non-adversarial development cases, versus 19/40 for round two and
16/40 for round three. It still has regressions and is not release-ready.
[The run report](runs/2026-10-17-round4/README.md) includes reproduction commands,
raw predictions, artifact hashes, the precision comparison, and adversarial review.


## Prompt-only identity-edit check

An explicit instruction to omit redundant edits did not improve the current
4-bit model: both prompts produced 17/24 exact training-sample outputs. The
production prompt remains unchanged. [The paired diagnostic](runs/2026-10-17-round5/README.md)
records the generations, rejected change, and next experiment boundary.


## Focused training-fit experiment

Training on the fixed 24-example diagnostic set eliminated its seven 4-bit
failures, reaching 24/24. Swift exact outputs improved from 21/40 to 24/40 on
existing development cases and 4/12 to 7/12 on newly authored unseen cases.
Validation loss and three development regressions prevent replacement of the
previous candidate. [The diagnostic report](runs/2026-10-17-round6/README.md)
records the selection decision, limitations, and next training boundary.


## Balanced error-focused continuation

Retaining all 172 training records while oversampling seven known failures
improved validation loss from 0.042 to 0.030. The 4-bit Swift result is 32/52
exact non-adversarial development outputs, versus 25/52 for round four and
31/52 for the narrow round-six diagnostic. Individual regressions and a failing
training control remain; this is not a release candidate. See
[the complete comparison](runs/2026-10-17-round7/README.md).


## Expanded span/context coverage

The corpus now contains 262 training and 47 validation records, plus the original
8 test records. A further 16 separately authored cases live in
`data/round8-holdout.jsonl`. The 200-step continuation did not beat its starting
checkpoint on expanded-validation loss, so round seven remains the experimental
model. It scored 8/16 on the new cases. [The run report](runs/2026-10-17-round8/README.md)
records the data, selection rule, failures, and next diagnostic boundary.


## Output-level checkpoint selection

Comparing existing 4-bit checkpoints through Swift found that round eight step
200 improves exact validation outputs from 26/47 to 38/47 despite worse token
loss. It then improved separate evaluation outputs from 40/68 to 49/68. The
preferred experimental export is `.context/cleanup-round9/step-200/candidate-4bit`.
It remains unready for release because of model-quality regressions. The accepted
misplaced period in the control-character fixture was fixed by the guard below. [The ranking report](runs/2026-10-17-round9/README.md)
contains the fixed protocol, raw outputs, comparisons, and adversarial review.


## Control-character corruption guard

The validator and Python mirror now reject nonempty model plans when raw text
contains non-whitespace control characters. The captured bad punctuation edit
now falls back to raw text; the other 78 model-evaluation results are unchanged.
20 Python and 23 Swift tests pass. [The verification report](runs/2026-10-17-control-guard/README.md)
records the before/after results and the intentionally conservative input policy.


## Optional NVIDIA training pilot

[The CUDA benchmark guide](CUDA_BENCHMARK.md) provides a bounded 20-step probe
for an existing Linux NVIDIA host using the same pinned MLX stack. CUDA model
compatibility and speedup remain unmeasured; no cloud resources have been rented.


## Complete-pass continuation

A further full 262-record training pass lowered token loss but only tied the
existing 38/47 exact validation outputs, with four improvements and four
regressions. The predeclared tie-break retains the existing experimental model;
no additional evaluation or release promotion was warranted. See the
[full-pass report](runs/2026-10-18-full-epoch/README.md).
