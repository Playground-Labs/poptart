# Cleanup model training

This is a clean-room, reproducible recipe for Poptart's task-specific Cleanup model. Inputs are limited to manually authored synthetic examples committed here or redistributable public sources with an individual provenance record. User Dictations, Target Context, Personal Vocabulary, history, audio, clipboard contents, application content, logs, telemetry, support data, and private operational data are prohibited.

The checked-in corpus is `CC0-1.0`, authored for Poptart, and contains invented names and applications only. Adding a source requires its stable URL, immutable revision, license, author, and redistribution rationale in every JSONL record. The verifier rejects unknown provenance kinds, missing licenses, and fields associated with private product data.

## The training target is a Cleanup Edit Plan

The model decodes only the Cleanup Edit Plan schema, so that is what it is trained to emit — never a rewritten transcript. Each generated assistant message is the compact plan document followed by the `<END_PLAN>` stop marker, exactly what `BoundedEditPlanParser` accepts:

```
{"v":1,"e":[{"s":0,"e":1,"r":"","c":"filler"},{"s":6,"e":6,"r":".","c":"punctuation"}]}<END_PLAN>
```

The system message is `CleanupPrompt.cleanupSystemInstruction` and the user message is the byte-counted untrusted-data payload `CleanupPrompt.build` produces, so training inputs have the same shape as inference inputs. `mask_prompt: true` in `config/lora.yaml` means only the plan contributes loss.

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

1. On Apple Silicon with macOS 26, create a fresh Python 3.12 environment and install `requirements-macos26-arm64.lock` with hash checking. This reproduces the 53 package versions used by the retained experiments; the development training environment is separate from the app's macOS 15 minimum.
2. Obtain `Qwen/Qwen3.5-2B` at revision `15852e8c16360a2fea060d615a32b45270f8a8fc` under its Apache-2.0 license, convert it to four-bit affine/group-64 as retained in the preparation evidence, and place it at the local path in `config/lora-2b.yaml`. Network access is an explicit preparation step, never part of Poptart.
3. Run `python3 Training/prepare_corpus.py`; the script deterministically validates provenance, proves every Cleanup Edit Plan reproduces its clean text, and creates MLX chat JSONL splits.
4. Run `python3 Training/train.py --config Training/config/lora-2b.yaml` in that environment.
5. Follow the chosen experiment’s export step. Current adapter candidates retain the unchanged four-bit `base/` plus separate `adapters/`; re-fusing them into four-bit weights caused measured accuracy loss. Earlier float-base experiments fused first and then quantized once with `mlx_lm.convert --q-bits 4 --q-group-size 64 --q-mode affine`.
6. Run the exact production prompt/tokenizer/artifact evaluation and physical 8 GB M1 benchmark. Only the release script may populate hashes and measurements.

No trained weights are checked into the repository; local pilot results do not establish release quality or latency.

The current corpus reproduces a new training run, not an earlier experiment. Use that experiment’s
frozen `--data` directory to reconstruct its candidate. The current adapter lineage starts at the
recognition-format experiment; the earlier pilot, refinement and coverage models are not ancestors:

| Stage | Starting weights | Frozen input directory | Training / retained checkpoint | Export |
| --- | --- | --- | --- | --- |
| Recognition | Pinned unquantized Qwen base | `experiments/recognition-inputs` | 1,200 / 1,100 | Fuse into float base, then four-bit affine/group-64 |
| Recovery | Recognition four-bit artifact | `experiments/recognition-inputs` | 600 / 600 | Historical four-bit fusion, producing `quant-recovery-qwen-4bit` |
| Composition | Recovery four-bit artifact, fresh LoRA | `experiments/composition-inputs` | 1,200 / 600 | Keep base and F32 adapter separate |
| Vocabulary | Same recovery base, resume composition adapter | `experiments/vocabulary-inputs` | 600 / 600 | Keep base and F32 adapter separate; not promoted |
| Boundary | Same recovery base, resume vocabulary adapter | `experiments/boundary-inputs` | 600 / 500 | Keep base and F32 adapter separate; not promoted |
| Low rate | Same recovery base, resume composition adapter | `experiments/boundary-inputs` | 600 / 600 | Keep base and F32 adapter separate; not promoted |

Recovery fusion is part of this candidate’s recorded ancestry, not a recommendation for subsequent
exports. Reproducing a lineage does not establish matching tensor bytes or release measurements;
evaluate and identify every resulting artifact again. No selected release weights exist yet.

The recognition ancestor uses the same `config/lora.yaml` with:

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/base-qwen \
  --data Training/experiments/recognition-inputs \
  --iters 1200 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/recognition-adapters --test
```

Select the recorded checkpoint by copying its weights to a fresh adapter directory as
`adapters.safetensors` alongside that run’s `adapter_config.json`. For this ancestor, select
`0001100_adapters.safetensors`, fuse against `base-qwen`, then quantize to
`recognition-qwen-4bit` with the exact four-bit settings above. The recovery export command and
input hashes are retained in [its evidence](experiments/quant-recovery-2026-09-16.json).


```sh
uv venv --python 3.12 .build/training-venv
uv pip sync --python .build/training-venv/bin/python --require-hashes Training/requirements-macos26-arm64.lock
uv pip check --python .build/training-venv/bin/python
```

The lock was verified in a separate clean environment against
`experiments/python-environment-2026-09-16.txt`. To regenerate it with the same versions:

```sh
MACOSX_DEPLOYMENT_TARGET=26.0 uv pip compile Training/requirements.txt \
  --constraints Training/experiments/python-environment-2026-09-16.txt \
  --generate-hashes --python-version 3.12 --python-platform aarch64-apple-darwin \
  --output-file Training/requirements-macos26-arm64.lock
```

## Seed expansion

The first authored expansion brings the corpus to **81 records**: 54 train, 14 valid,
13 test. `coverage` is optional authoring metadata; it is not included in the model prompt.
The new examples cover punctuation and capitalization, questions, filler removal, adjacent
repetitions, vocabulary spelling, mid-sentence joins, deterministic Explicit Corrections,
and no-op preservation of negation, identifiers, amounts, URLs, and ordinary uses of “like”
and “I mean.” All names, contexts, and utterances are invented.

`prepare_corpus.py` rejects duplicate utterances (case/punctuation/whitespace normalized)
across splits and direct overlap with any evaluation fixture. Within training, it permits only
distinct supplied case/spacing variants of the same vocabulary identities; repeated or reordered
vocabulary sets still reject. Evaluation-list membership overrides a record's split tag. This catches direct leakage,
not semantic paraphrases; authors must still review topic and template overlap across splits.
The native Cleanup test also runs every training/gold label through the actual Swift validator
and requires reserved corrections to equal what the runtime derives from the transcript.

This is a seed set, not a sufficient fine-tuning or release dataset. Next expand independently
reviewed examples, especially longer Dictations, punctuation ambiguity, correction boundaries,
and preservation cases. Keep validation/test text out of training and freeze a larger release
evaluation set before comparing models. Do not interpret the default 1,200 training iterations
as a tuned schedule for this small seed. The bounded pilot below is development evidence only.

## First baseline and bounded LoRA pilot

The native baseline exposed schema copying and missing stop markers. Eighteen additional, distinct
training examples target format compliance (six no-ops, six short commands, three filler edits,
three context joins). That pilot used **99 records: 72 train / 14 valid / 13 test**. Held-out
utterances were not copied into the expansion.

Two training/inference mismatches were fixed before the pilot: generated prompts now omit absent
`selectedText`, preserve the Swift system instruction's two leading spaces, and are checked byte
for byte by the native corpus test. The pinned MLX trainer's wrapper enables thinking by default;
`train.py` explicitly disables it when formatting both full chats and masked prefixes. Its preflight
rejects mismatched masks or sequences that would be truncated. It uses local models/data, disables
remote tokenizer code and online Hub access, and refuses to overwrite an adapter directory.

```sh
uv venv --python 3.12 .build/training-venv
uv pip install --python .build/training-venv/bin/python -r Training/requirements.txt
python3 Training/prepare_corpus.py
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/base-qwen \
  --iters 80 --steps-per-eval 40 --save-every 80 \
  --adapter-path .build/pilot-adapters --test
```

Obtain the base files from `Qwen/Qwen3.5-0.8B` at the pinned revision before running this command;
model download is an explicit preparation operation. The pilot uses the unquantized base for LoRA,
then fuses and quantizes to 4-bit affine/group-64 for comparison with an identically quantized base:

```sh
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 .build/training-venv/bin/mlx_lm.fuse \
  --model Models/Artifacts/base-qwen --adapter-path .build/pilot-adapters \
  --save-path Models/Artifacts/pilot-fused
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 .build/training-venv/bin/mlx_lm.convert \
  --hf-path Models/Artifacts/pilot-fused --mlx-path Models/Artifacts/pilot-qwen-4bit \
  --quantize --q-bits 4 --q-group-size 64 --q-mode affine
```

Use `Evals/baseline.py` with the pilot directory and a fresh output directory for comparison. The
80-step run is a bounded feasibility experiment, not a selected release model or tuned training
schedule. Base/fused/quantized weights stay under gitignored `Models/Artifacts`; local adapters and
logs stay under `.build`. Do not populate production release metadata from this experiment.

The [September 16 experiment](experiments/pilot-2026-09-16.json) retains both runs' predictions,
failures, artifact hashes, runtime/environment pins, and training configuration/log. Both final
runs used the same Swift runtime on an M5 Pro and exited successfully.

| Measure | Quantized base | Quantized 80-step pilot |
| --- | --- | --- |
| Exact gold edit plan | 0/12 | 4/12 |
| Meaning preservation | 7/12 | 8/12 |
| Vocabulary preservation | 2/2 | 2/2 |
| Context fit | 12/12 | 12/12 |
| Adversarial fallback expectation | 11/11 | 3/11 |

The base copied the schema without its stop marker on every fixture. The pilot produced accepted
plans on 11/12 gold fixtures, but still missed fillers, repetition, capitalization, and vocabulary
correction; one reversed span was rejected. Validation loss ended at 0.092 and test loss at 0.074;
low teacher-forced loss did not establish exact generation quality. The fallback-only adversarial
metric is not a safety verdict: conservative edits account for several pilot misses, while hidden
and control characters remain in two accepted outputs. Broader labels and a behavior-based safety
evaluation are needed before selecting a release model.

This run also exposed a native shutdown race: stopping the output stream did not wait for MLX's
generation task. The adapter now cancels and joins that task before finishing, replacing a request,
or unloading. Re-running `Evals/baseline.py` on these local artifacts exercises marker completion,
rejected plans, repeated requests, and process shutdown; a nonzero runner exit rejects the report.


## Frozen evaluation boundary

`Evals/fixtures/release-v1` is excluded from training, with recursive leakage checks in corpus
preparation and byte-pinned labels. Keep it frozen while iterating on the development suite;
v1 approval was withheld and v2 supersedes it. See the [evaluation policy](../Evals/README.md#frozen-release-holdout)
for acceptance criteria and review requirements. The pilot table above is historical schema 2:
its fallback-only safety and permissive context scores have been superseded. Re-scoring the same
saved predictions under schema 3 gives the pilot **9/11 behavioral safety and 6/12 context fit**
(base: 11/11 and 1/12); exact plans remain 4/12 versus 0/12. No additional training occurred.


## Second bounded pilot: no promotion

That experiment used **147 records: 120 train / 14 valid / 13 test**. Forty-eight additional
training-only examples cover capitalization, filler positions, repeated words at varied offsets,
and invented vocabulary joins. Validation/test splits and frozen release fixture bytes are unchanged.

A second run used the same pinned base and LoRA recipe, with `--iters 160 --steps-per-eval 80
--save-every 160 --adapter-path .build/refine-adapters --test`. Fuse/quantize as above, using
`refine-adapters`, `refine-fused`, and `refine-qwen-4bit` paths. Final validation loss was 0.097;
test loss was 0.057. More training data and more steps changed together, so this is not a controlled
ablation. Lower teacher-forced loss did not produce better exact generation quality.

Both quantized pilots were rerun with the same current native runtime and development scorer:

| Measure | 80-step pilot | 160-step pilot |
| --- | --- | --- |
| Exact gold edit plan | 4/12 | 3/12 |
| Meaning preservation | 8/12 | 9/12 |
| Vocabulary preservation | 2/2 | 2/2 |
| Context fit | 6/12 | 5/12 |
| Behavioral adversarial safety | 11/11 | 11/11 |
| Runtime consistency | 23/23 | 23/23 |

The [comparison evidence](experiments/refine-2026-09-16.json) retains reports, predictions, failures,
runtime/model/data identities, environment, and training logs. Safety gains over historical predictions
come from the stricter runtime guard on original Unicode, not demonstrated model learning. Both
artifacts remain experimental; neither meets release quality. The 160-step model is not promoted.
No candidate has been run on the frozen release holdout. Version 2 later received scoped independent agent approval for labels and policy; no model is approved.


Release holdout revision 2 supersedes v1 for future release scoring; both versions are excluded
from training. It inherits v1 gold text and corrects adversarial labels before any holdout model
query. The old development control fixture contained a literal escape string, so the historical
11/11 safety scores above do not establish actual control-byte coverage. Native probes now cover
real control bytes. See the [v2 review](../Evals/fixtures/release-v2/REVIEW.md) for approval status.


The [subsequent development rerun](experiments/pilot-2026-09-16-v2-development.json) uses the same
80-step weights with corrected control bytes and updated safe-output labels. It confirms 11/11
behavioral safety and all eight separate development native probes, with exact accuracy still
4/12, meaning 8/12, and context 6/12. No further training or holdout model inference occurred.

## Extended run and coverage expansion

The [1,200-step experiment](experiments/extended-2026-09-16.json) used the same 147 records.
Checkpoint 800 had the lowest validation loss among saved checkpoints (0.069); selection
preceded native development evaluation. After fusion and 4-bit quantization, it reached
6/12 exact plans, 11/12 meaning, 9/12 context, 2/2 vocabulary, 11/11 safety, and
23/23 runtime consistency. It is not a release candidate. The exact prior input files
are retained in `experiments/extended-inputs` and match the experiment's input hashes.

The coverage experiment used **244 records: 200 train / 22 valid / 22 test**. The expansion adds
97 independently authored context, Unicode, reserved-correction, and sentence-boundary
examples. Twelve earlier repetition labels now consistently delete the first duplicate,
matching the established labeling policy; their resulting text is unchanged. All plans
pass validation, direct split/fixture leakage checks, and an independent label review.
The model has not queried the frozen release holdout.

That bounded experiment kept the same base, recipe, and 1,200-step budget, retaining
every 100-step validation checkpoint. Select the lowest validation loss (earlier step breaks
ties) before native evaluation. Changed data means this is not a steps-only ablation.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/base-qwen \
  --iters 1200 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/coverage-adapters --data Training/experiments/coverage-inputs --test
```


The [coverage result](experiments/coverage-2026-09-16.json) selected checkpoint 1200
(validation loss 0.002, test loss 0.009) before native evaluation. It reached **8/12 exact**,
10/12 meaning, 11/12 context, 2/2 vocabulary, 11/11 safety and 23/23 runtime consistency.
The exact 244-record inputs are preserved in `experiments/coverage-inputs`.
A real recognition replay under IP denial completed all 12 authored speech fixtures and
history readback, but only 8 produced accepted Cleanup plans; the strict privacy gate failed.
These synthetic speech results do not measure representative human recognition accuracy.

The recognition-format corpus contains **364 records: 300 train / 32 valid / 32 test**. Its 120 new authored
examples cover already capitalized/punctuated recognition text, preservation, vocabulary joins,
terminal fillers, short commands and sentence splits. They were authored independently of replay
utterances. This addresses an input distribution gap: most earlier examples were unpunctuated,
while actual recognition commonly supplies punctuation. A shared edit-applier spacing defect
exposed during label validation was fixed in Swift and the Python mirror.
The [completed recognition-format experiment](experiments/recognition-2026-09-16.json) selected
checkpoint 1100 (validation loss 0.007; final-step test loss 0.017) before native evaluation.
It reached **8/12 exact**, 9/12 meaning, 11/12 context, 2/2 vocabulary, 11/11 safety and
23/23 runtime consistency. Exact accuracy did not improve and meaning preservation regressed
from the coverage candidate, so this model is not promoted. The exact 364-record inputs are
retained in `experiments/recognition-inputs`; shared template families across splits limit
what the low validation loss establishes. The frozen release holdout remains unqueried.

## Quantization diagnosis

The [native comparison](experiments/recognition-diagnosis-2026-09-16.json) reran the selected
checkpoint on development and the existing 32-record training validation split. Unquantized
weights scored 9/12 development exact and 28/32 validation exact. Four-bit group-64 weights scored
8/12 and 21/32; reducing the quantization group to 32 recovered validation to 24/32. This isolates
a substantial quantization loss, with additional generalization failures still present before
quantization. Python and Swift input token counts matched on all 12 development examples and raw
greedy output matched on 10; the repetition, vocabulary, and trailing-filler failures persisted
across both runtimes. Token-level validation loss alone did not predict complete-plan correctness.
The evidence retains predictions, identities, failures and the Python comparison script/environment.

The historical recovery experiment used the existing group-64 artifact as the local LoRA base,
the same 364 records and recipe, and 600 additional steps. Selection used lowest saved validation
loss (earlier step wins ties) before native free-generation validation and development scoring.
Its evaluated artifact fused the adapter back into four-bit weights; an unfused result did not
establish that artifact's accuracy. No production artifact or release threshold changed.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/recognition-qwen-4bit \
  --iters 600 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/quant-recovery-adapters --data Training/experiments/recognition-inputs --test
```

The [completed recovery run](experiments/quant-recovery-2026-09-16.json) selected step 600
(validation loss 0.009; final-step test loss 0.014). The fused four-bit artifact improved existing
validation exact accuracy from 21/32 to 25/32, but development remained **8/12 exact and 9/12
meaning**, with 12/12 context, 2/2 vocabulary, 11/11 safety and 23/23 runtime consistency. It is
not promoted. Measurements include all outcomes and remain Cleanup-only evidence on an M5 Pro;
they do not establish whole-app memory or release-to-delivery performance on an 8 GB M1.

## Gemma 3 development challenger

The [stock baseline comparison](experiments/challenger-baselines-2026-09-16.json) uses the same
native runner, 12 development gold cases and 11 adversarial cases. Both stock models scored
0/12 exact; stock Gemma's prompt token counts agree with Python on all 23 cases. The trained
recovery Qwen scored 8/12. Retained latency and memory observations include fallbacks; a model
that quickly rejects a request is not thereby a better Cleanup model. These single runs on an
M5 Pro establish neither an M1 performance pass nor a trained challenger selection.


The evaluation-only challenger uses `google/gemma-3-1b-it` revision
`dcc83ea841ab6100d6b47a070329e1ba4cf78752`, obtained after the user granted access.
It stays outside the product model selection. Gemma has no system chat role, so join the
identical system instruction and payload into its first user turn, matching the native SPI:

```sh
.build/training-venv/bin/python - <<'PYTHON'
import json
from pathlib import Path
source = Path('Training/experiments/recognition-inputs')
output = Path('.build/gemma3-training-data')
output.mkdir(exist_ok=True)
for split in ('train', 'valid', 'test'):
    rows = []
    for line in (source / f'{split}.jsonl').read_text().splitlines():
        system, user, assistant = json.loads(line)['messages']
        assert [system['role'], user['role'], assistant['role']] == ['system', 'user', 'assistant']
        rows.append({'messages': [{'role': 'user', 'content': system['content'] + '\n\n' + user['content']}, assistant]})
    (output / f'{split}.jsonl').write_text(''.join(json.dumps(row, separators=(',', ':'), ensure_ascii=False) + '\n' for row in rows))
PYTHON
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/base-gemma3-1b \
  --data .build/gemma3-training-data --iters 1200 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/gemma3-recognition-adapters --test
```

This uses the same 364 records, seed, rank, last-16-layer adaptation, learning rate and step budget
as the Qwen recognition-format experiment. Different architectures and tokenizers make this a
recipe comparison, not equal compute. Select the lowest logged validation loss among saved
checkpoints (earlier step breaks ties) before native scoring, then fuse against the pinned float
base and quantize to four-bit affine/group-64. Evaluate with `Evals/baseline.py --challenger gemma3`.
No challenger training or evaluation consumes the frozen release holdout.

The [trained Gemma comparison](experiments/gemma3-recognition-2026-09-16.json) selected step 1200
(validation loss 0.027; final-step test loss 0.039). Native four-bit evaluation scored **0/12
development exact** and **4/32 existing validation exact**, with 11/11 adversarial safety. The
unquantized checkpoint scored 18/32 validation exact. Python and Swift prompt counts agree on
all 12 development cases; both runtimes produce malformed or incorrect four-bit plans. No model
is promoted: Qwen remains the stronger candidate, and neither meets the release quality gate.

## Balanced edit composition experiment

The corpus now has **512 records: 448 train / 32 valid / 32 test**. The 148 new training-only
examples add 48 noun/verb repetitions, 40 terminal fillers (including short commands), 40 known
vocabulary joins and 20 preservation counterexamples. Validation and test files are byte-identical
to the recognition-format experiment. Both independent label reviews cleared after replacing
ambiguous modifier repetition labels and balancing each filler across both casing conditions.
The native Swift contract and Python tooling accept every label. Exact inputs and the review
record are retained in [composition-inputs](experiments/composition-inputs).

This is still synthetic coverage: repeated sentence forms, early repetition positions and
two-word CamelCase joins limit generalization. No fixture output is a training target and the
frozen release holdout has not been queried. The unfused recovery adapter also missed the same
development categories, so requantization alone does not explain the accuracy ceiling.

The historical fused composition run started from the four-bit recovery artifact with the same
rank, layer count, learning rate and seed. It trained for 1,200 steps and selected minimum logged
validation loss among saved checkpoints (earlier step wins ties) before native scoring. That run
fused back into four-bit weights; the resulting accuracy loss is documented below. To reproduce
the current native adapter candidate, use retained checkpoint 600 and the separate `base/` and
`adapters/` export below. Changing both data and starting checkpoint prevents a single-factor
comparison.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --iters 1200 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/composition-adapters --data Training/experiments/composition-inputs --test
```

The [completed composition run](experiments/composition-2026-09-16.json) selected checkpoint 600
(validation loss 0.004; final-step test loss 0.003). The fused four-bit model scored **9/12 exact**
on development and 26/32 on existing validation. Development meaning preservation reached 10/12;
context, vocabulary, adversarial safety and runtime consistency passed their finite suites.
Trailing-filler removal improved, but repetition, a vocabulary join and a sentence split still
failed. The model is not promoted and the release holdout remains unqueried. Retained measurements
are Cleanup-only M5 observations, not physical M1 release evidence.

A free-generation diagnostic on the 88 new repetition/vocabulary **training** examples exposed
export loss: the selected Python adapter scored 88/88 exact, but fusing into four-bit weights
reduced the same Python runtime to 26/88. The native fused model scored 25/88 and matched Python's
raw fused output on 83/88; all prompt token counts matched. These are training-fit measurements,
not independent quality evidence. The unfused adapter scored 11/12 exact on development, still
missing the vocabulary join. The experiment retains all predictions. Next verify the unchanged
four-bit base plus separate adapter in the native runtime before adding more training steps;
Python adapter results cannot establish production quality or M1 latency.

The native loader also supports an unfused artifact with separate `base/` and `adapters/` trees.
Keep the original four-bit base unchanged; copy the selected adapter configuration and tensors
without calling `mlx_lm.fuse`. The composition adapter contains 248 float32 tensors (14.46 MB),
in addition to the four-bit backbone. It is one task-specific model, with both trees covered by
the signed inventory and native evaluation identity. The extra operations have a latency cost;
preserving accuracy does not establish the release performance gate.

```sh
mkdir Models/Artifacts/composition-qwen-adapter-v2
cp -cR Models/Artifacts/quant-recovery-qwen-4bit Models/Artifacts/composition-qwen-adapter-v2/base
cp -cR .build/composition-selected-adapters Models/Artifacts/composition-qwen-adapter-v2/adapters
.build/training-venv/bin/python Evals/baseline.py \
  --runner .build/out/Products/Debug/PoptartCleanupEval \
  --model Models/Artifacts/composition-qwen-adapter-v2 \
  --output-directory .build/composition-adapter-development
```

The [native adapter comparison](experiments/composition-adapter-2026-09-16.json) preserves all
88/88 measured training examples and reaches 30/32 existing validation and **11/12 development
exact plans**. The remaining vocabulary join is rejected safely; meaning and context each score
11/12, while vocabulary preservation, adversarial safety and runtime consistency pass their suites.
It remains a development candidate. The reviewed M5 run observed 1,699 ms Cleanup-only p99 and
1.82 GB peak physical footprint; neither establishes the whole-app 8 GB M1 requirement. Real native
probes reject missing tensors, wrong shapes and an empty adapter graph before producing predictions.

The [BF16 adapter diagnostic](experiments/adapter-precision-2026-09-16.json) preserved the exact
raw plans, delivered text and outcomes on all 23 development/adversarial and 99 training-fit/
adversarial requests. Casting only the adapter halves its file size to 7.25 MB. Observed M5
physical peaks fell to 1.25/1.28 GB, but p99 increased to 2,300/2,524 ms versus 1,699/1,591 ms
for the earlier F32 runs. These sequential runs are not a controlled speed comparison. No
performance pass or promotion follows; retain the F32 training checkpoint for the next run.

## Literal vocabulary spelling follow-up

This experiment's corpus has **560 records: 496 train / 32 valid / 32 test**. The 48 independently
reviewed additions cover eight joins each with Titlecase, lowercase and ALLCAPS spellings,
eight literal spaced names, eight already-correct names and eight ordinary physical-object
phrases that must remain unchanged despite resembling a listed name. The physical-object names
also have positive application examples; distractors rotate among positive names. Target position
is balanced independently of initial casing. Existing validation/test bytes remain unchanged.
[Exact inputs and the predeclared plan](experiments/vocabulary-inputs/plan.json) are retained.

Resume the selected composition adapter on its unchanged four-bit recovery base for 600 steps.
Keep the previous seed, rank, layer count and learning rate. Select minimum logged validation
loss among saved checkpoints, breaking ties at the earliest step, before native scoring. Export
base and adapter separately without fusion. This is a bounded synthetic-data follow-up, not
independent generalization evidence; the release holdout remains unqueried.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/vocabulary-inputs \
  --resume-adapter-file .build/composition-selected-adapters/adapters.safetensors \
  --iters 600 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/vocabulary-adapters --test
```

The [completed vocabulary follow-up](experiments/vocabulary-2026-09-16.json) selected step 600
(validation loss 0.005; test loss 0.006). Native development fell to **10/12 exact**, while existing
validation remained 30/32. The vocabulary join improved, but a sentence split regressed and an
emoji-adjacent word received an invalid vocabulary edit. Meaning preservation passed 12/12 on
development; context passed 11/12 and adversarial safety 11/11. The candidate is not promoted.
The prior 11/12 adapter is retained, and the release holdout remains unqueried.

A [predeclared parameter-blend comparison](experiments/adapter-blends-2026-09-16.json) tested
25%, 50% and 75% of the vocabulary adapter's parameters against the preceding composition
adapter. All three scored the same 30/32 validation exact, 31/32 meaning and context, and passed
adversarial/runtime checks. The declared tie-break retained the original composition adapter;
no extra development or release-holdout query followed. Parameter interpolation did not recover
better validation behavior, so none of the blends is promoted.

## Boundary and literal-casing follow-up

This experiment's corpus has **624 records: 560 train / 32 valid / 32 test**. The 64 reviewed additions
cover 24 independent-clause repairs at varied span positions, 16 inline-symbol preservation
examples, 16 filler removals before already-capitalized `I` or names, and eight coordinated lists
whose commas must stay. Each filler has both casing/terminal-punctuation and subject-type/
terminal-punctuation combinations balanced. Validation/test files remain unchanged.
[Exact inputs, review and predeclared plan](experiments/boundary-inputs/plan.json) are retained.

Resume the vocabulary adapter on its unchanged four-bit base for 600 steps. Score all six saved
checkpoints with the native existing validation/adversarial suites. Require all safety/runtime
checks, then rank meaning preservation, context fit and exact plans; break ties with lower logged
validation loss and earlier step. Record selection before a single development evaluation.
The existing validation set has no vocabulary-preservation denominator and cannot establish a
full quality pass. No frozen release-holdout query is part of this experiment.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/boundary-inputs \
  --resume-adapter-file Models/Artifacts/vocabulary-qwen-adapter/adapters/adapters.safetensors \
  --iters 600 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/boundary-adapters --test
```

The [completed boundary run](experiments/boundary-2026-09-16.json) selected checkpoint 500
before its development evaluation. It scored 31/32 validation exact, but **10/12 development
exact**, 12/12 meaning and 10/12 context. Vocabulary, adversarial safety and runtime consistency
passed their finite suites. The remaining development failures attempted a redundant vocabulary
insertion and exceeded the edit budget on a short symbol-containing utterance. It is not promoted.

A [predeclared blend comparison](experiments/boundary-blend-plan-2026-09-16.json) interpolated
the composition and selected boundary adapter parameters at 25%, 50% and 75% boundary weight.
This interpolates LoRA parameters, not model outputs or exact weight deltas. The 75% blend was
selected on **32/32 validation exact**, then scored only **9/12 development exact**.
[Complete results](experiments/boundary-blends-2026-09-16.json) are retained; no blend is promoted.
Perfect performance on this small validation set did not establish generalization.

## Lower learning rate comparison

The [predeclared plan](experiments/low-rate-plan-2026-09-16.json) returns to the retained 11/12
composition adapter, using the same fixed 624-record corpus, a learning rate of `3e-6` and batch
size two. Starting adapter, learning rate and batch size differ from the boundary run, so this is
a recipe comparison, not a single-factor ablation. Checkpoint selection uses the same native
validation, safety and runtime rules above, before one development evaluation. No release-holdout
query is included.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/boundary-inputs \
  --resume-adapter-file Models/Artifacts/composition-qwen-adapter-v2/adapters/adapters.safetensors \
  --learning-rate 0.000003 --batch-size 2 \
  --iters 600 --steps-per-eval 100 --save-every 100 \
  --adapter-path .build/low-rate-adapters --test
```

The [completed comparison](experiments/low-rate-2026-09-16.json) selected checkpoint 600:
checkpoints 400–600 each scored 32/32 validation exact, but 400 and 500 failed one adversarial
case. Checkpoint 600 passed safety/runtime checks and then scored **10/12 development exact**,
11/12 meaning and 11/12 context. It left a split vocabulary term unchanged and produced an
invalid plan for a short symbol-containing utterance. It is not promoted; the retained model
remains the composition adapter at 11/12 development exact. These results used the unchanged
evaluator from the predeclared run, before the subsequent URL/numeric-literal validator fix.

That independently reproduced validator defect has since been fixed. Both retained models were
rechecked without any change to their 46 development/adversarial outputs. A
[predeclared runtime comparison](experiments/literal-runtime-selection-plan-2026-09-17.json)
now repeats the same checkpoint eligibility and ranking rule on the six existing low-rate
checkpoints using the repaired runtime. No further training or release-holdout query is involved;
selection will again be recorded before its development evaluation.

The [completed runtime comparison](experiments/literal-runtime-selection-2026-09-17.json)
made all six checkpoints safety-eligible. Checkpoints 400–600 retained 32/32 validation exact;
equal logged loss selected the earlier checkpoint 400. Its development result was still
**10/12 exact**, with the same vocabulary and short-symbol failures as checkpoint 600.
It is not promoted. Improving rejection behavior did not improve model accuracy.

## Fresh adapter on the stock quantized base

For a fresh checkout, place the pinned upstream Qwen snapshot from step 2 at
`Models/Artifacts/base-qwen`, then create the stock quantized artifact with the locked environment:

```sh
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 .build/training-venv/bin/mlx_lm.convert \
  --hf-path Models/Artifacts/base-qwen --mlx-path Models/Artifacts/baseline-qwen-4bit \
  --quantize --q-bits 4 --q-group-size 64 --q-mode affine --dtype bfloat16
```

The [predeclared clean-base recipe](experiments/clean-base-plan-2026-09-17.json) trains a fresh
rank-eight adapter on the stock four-bit affine/group-64 Qwen artifact. All seven base files
match the retained stock-baseline hashes. It uses the unchanged 624-record corpus, batch size
two, learning rate `1e-5`, and 1,200 iterations. Six checkpoints saved every 200 steps use the
same native validation ranking and safety/runtime eligibility rule before one development run.
Export keeps the base and F32 adapter separate.

This is a separate lineage from recognition/recovery/composition. Starting weights, adapter,
learning rate and training length differ from the low-rate run; it is not a single-factor test
of fusion damage. The [completed experiment](experiments/clean-base-2026-09-17.json) selected
step 1,000 before development evaluation: 27/32 validation exact, 32/32 meaning preservation,
31/32 context fit, 11/11 adversarial safety, and 43/43 runtime consistency. All six checkpoints
passed safety/runtime; their exact scores were 14, 20, 26, 28, 27, and 27 respectively. Step
1,000 won because the declared ranking prioritizes meaning preservation and context fit over
exact plans. Final-step validation loss was 0.005 and test loss was 0.013.

Development scored 9/12 exact, 11/12 meaning preservation, 9/12 context fit, 2/2 vocabulary
preservation, 11/11 adversarial safety, and 23/23 runtime consistency. Failures were an unlisted
vocabulary replacement (raw fallback), omitted sentence-initial capitalization after preceding
context, and an unsupported vocabulary edit beside an emoji (raw fallback). This did not improve
the retained composition adapter's 11/12 development result. No promotion or frozen release
holdout query followed.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/baseline-qwen-4bit \
  --data Training/experiments/boundary-inputs \
  --learning-rate 0.00001 --batch-size 2 \
  --iters 1200 --steps-per-eval 200 --save-every 200 \
  --adapter-path .build/clean-base-adapters --test
```

A subsequent [paired vocabulary-instruction diagnostic](experiments/vocabulary-instruction-2026-09-17.json)
used the retained composition adapter and all 23 existing development/adversarial inputs. Python
greedy inference reproduced every native control plan and delivered output. Adding one fixed rule
requiring exact, case-sensitive Personal Vocabulary membership left the vocabulary failure
unchanged and regressed a sentence-initial capital after preceding context: exact development
output fell from 11/12 to 10/12. The variant was rejected without changing the production prompt
or validator. This is a Python diagnostic, not native validation of a candidate or release evidence.

Two native diagnostics then examined vocabulary copying with the retained composition adapter.
The [spelling matrix](experiments/vocabulary-spelling-2026-09-17.json) varied four compounds,
two sentence frames, three supplied spellings and an empty-vocabulary control. All 24 supplied
replacement strings were exact, but only 13 targeted the correct spans. Delivered text matched
in 21/32 cases, including three safe raw fallbacks; exact plans matched in 18/32. Familiar and
synthetic compounds had similar results. This does not support familiar spelling as the dominant
failure in that matrix.

The [position follow-up](experiments/vocabulary-position-2026-09-17.json) held CamelCase spelling
fixed across eight sentence frames and scored 17/32 exact. Moving the vocabulary term later in
the sentence often helped, but paraphrases at the same ordinal position also changed results.
This is sensitivity to both sentence frame and span position, not a simple position cutoff.
Both runs passed 11/11 adversarial checks and 43/43 runtime consistency checks; neither queried
the release holdout. These probes are development diagnostics, not representative quality
estimates. The fixed training corpus contains 111 vocabulary edits with start positions
`{1: 3, 2: 6, 3: 15, 4: 8, 5: 20, 6: 38, 7: 20, 8: 1}` and none at position zero.

The [reviewed position corpus](experiments/position-inputs/REVIEW.md) adds 144 train-only examples:
128 vocabulary edits evenly covering starts zero through seven, with two frames per position,
and 16 no-op preservation examples. Names, spelling styles and distractor order vary; software
context avoids ambiguous physical-object readings. The snapshot has **704 train / 32 validation /
32 test** records, with validation/test bytes unchanged. Native corpus contract validation,
37 Python tooling tests, and 2,861 repository checks pass; training preflight reports a longest
sequence of 427 tokens.

The [predeclared position experiment](experiments/position-plan-2026-09-17.json) retains the
corrected-runtime low-rate comparison's base, composition adapter, learning rate, batch size,
seed and 600 iterations. The added training data are the intervention. Six checkpoints use the
original validation ranking; the selected checkpoint then runs both diagnostic matrices and
development once. Diagnostic scores cannot select another checkpoint.

The [completed run](experiments/position-2026-09-17.json) selected step 500 before diagnostics or
development: steps 100 and 500 both passed all 32 validation exact/meaning/context checks,
with step 500's lower logged loss breaking the tie. Validation exact scores across all six
checkpoints were 32, 29, 30, 31, 32, and 30. All six passed 11/11 safety and 43/43 runtime checks.
The selected model improved the spelling diagnostic from 18/32 to 28/32 exact and the position
diagnostic from 17/32 to 28/32 exact. It still generated invalid vocabulary edits for four
empty-vocabulary controls; raw fallback preserved their text. Four position cases omitted the
vocabulary normalization and added a second terminal period.

Development remained below the retained composition model: 10/12 exact, 11/12 meaning,
10/12 context, 2/2 vocabulary preservation, 11/11 safety and 23/23 runtime consistency.
The vocabulary-join and emoji-adjacent cases fell back to raw. Final-step validation/test loss
was 0.003/0.003. This supports the targeted diagnostic improvement, not model promotion or
release readiness; the frozen release holdout remains unqueried.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/position-inputs \
  --resume-adapter-file Models/Artifacts/composition-qwen-adapter-v2/adapters/adapters.safetensors \
  --learning-rate 0.000003 --batch-size 2 --iters 600 \
  --steps-per-eval 100 --save-every 100 --adapter-path .build/position-adapters --test
```

A [candidate-span prototype](experiments/vocabulary-candidates-2026-09-17.json) supplied optional
vocabulary spelling edits in the untrusted payload while retaining model choice and the unchanged
validator. Paired Python runs used the retained composition adapter on 23 development/adversarial,
32 position-diagnostic, and eight previously authored physical-object examples. Development exact
output stayed 11/12; position output fell from 19/32 in the Python control to 15/32 with candidates.
The controls matched 53/55 retained native plans, so these Python scores are not native evidence.

Physical-object exact output was 1/8 in the control and 3/8 with candidates, but the variant also
introduced accepted changes from ordinary `blue envelope` and `maple branch` references to listed
application names, while retaining an existing `red lantern` error. Mechanical eligibility does
not establish intended meaning. The prototype was rejected; no production candidate field,
automatic vocabulary substitution, prompt change, or validator relaxation was introduced.

A [native physical-object comparison](experiments/physical-vocabulary-2026-09-17.json) then
evaluated the same eight existing training examples on composition, corrected-runtime low-rate
step 400, and position step 500. Exact plans scored 0/8, 7/8, and 5/8; meaning preservation scored
7/8, 7/8, and 6/8. All three passed 11/11 adversarial and 19/19 runtime checks. The position model
incorrectly changed ordinary blue-envelope and red-lantern references into application names.
These are training diagnostics, not independent quality estimates, and none qualifies for release.

Review of the paired name-positive training labels found ambiguous object readings, particularly
putting an invoice in a blue envelope. The [context corrections](experiments/context-inputs/REVIEW.md)
clarify seven utterances as software/application references and align eight positives' vocabulary
lists with their physical-object negatives. Both independent reviewers cleared the corrected
labels and unchanged partitions. All other 760 corpus lines remain byte-identical, including the
physical negatives, validation and test. The snapshot retains exact before/after records; earlier
experiment snapshots remain unchanged. This removes identified supervision ambiguity without
claiming it explains all model errors.

The [predeclared context experiment](experiments/context-plan-2026-09-17.json) keeps the position
run's base, starting adapter, seed, learning rate, batch size, and 600 iterations fixed. It selects
one of six checkpoints using the original native validation ranking before running the spelling,
position, and physical-object diagnostics and one development evaluation. Diagnostics do not
select a different checkpoint. Native corpus validation, all 37 tooling tests, 2,861 repository
checks, and training preflight pass.

The [completed context experiment](experiments/context-2026-09-17.json) selected step 400 before
diagnostics or development. Validation exact scores were 32, 29, 30, 32, 32, and 30 out of 32;
all six checkpoints passed safety/runtime. Steps 400 and 500 tied at 0.002 logged validation loss,
so the earlier checkpoint won. Final-step validation/test loss was 0.003/0.003. A repository build
replaced the evaluator during the first checkpoint-400 run; the identity guard rejected it.
The [recorded recovery](experiments/context-evaluation-restart-2026-09-17.json) repeated all six
validations with one retained evaluator and resource bundles, without retraining or changing selection.

Development scored 10/12 exact, 11/12 meaning, 10/12 context, 2/2 vocabulary, 11/11 safety, and
23/23 runtime consistency. The spelling and position diagnostics regressed to 25/32 and 26/32 exact.
Physical-object cases scored 4/8 exact and 5/8 meaning: blue-envelope, green-basket, and red-lantern
references were incorrectly changed into names. The model was rejected. Correcting the ambiguous
labels was warranted but did not solve overcorrection or improve development accuracy.

A coverage audit found 239 training examples with vocabulary edits versus 33 preservation examples
with supplied vocabulary. Only eight of those preservation examples describe ordinary physical
objects; the other 25 already contain canonical names. This motivates a prospective preservation
coverage experiment, not a causal conclusion or permission to weaken the validator.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/context-inputs \
  --resume-adapter-file Models/Artifacts/composition-qwen-adapter-v2/adapters/adapters.safetensors \
  --learning-rate 0.000003 --batch-size 2 --iters 600 \
  --steps-per-eval 100 --save-every 100 --adapter-path .build/context-adapters --test
```

## Preservation coverage experiment

The [preservation plan](experiments/preservation-plan-2026-09-17.json) adds 192 reviewed training
examples: 128 physical-object references with matching vocabulary, 32 application references with
empty vocabulary, and 32 with unrelated vocabulary. All existing 768 records remain byte-identical;
that experiment's corpus has 896 train / 32 validation / 32 test records. Independent reviews corrected
incidental distractor and ordering shortcuts before training; the [review](experiments/preservation-inputs/REVIEW.md)
and authoring scripts retain those checks. Native corpus validation, all 38 tooling tests, 3,437
repository checks, and the 427-token maximum-length preflight pass.

The recipe retains the context experiment's base, composition starting adapter, learning rate,
batch size, seed, and 600 iterations. Native validation selects among six checkpoints before the
existing diagnostics, a prospective 32-case unfamiliar-name probe, and one development evaluation.
The new probe pairs explicit physical and application uses of eight terms absent from training;
composition and context400 run as controls after selection. It cannot select another checkpoint
or substitute for the frozen release suite. The evaluator and resource bundles are retained away
from mutable build products. The [completed run](experiments/preservation-2026-09-17.json) selected step 500 before diagnostics:
validation exact scores were 30, 29, 29, 30, 32, and 30 out of 32. All six checkpoints passed
safety/runtime. Final-step validation/test loss was 0.003/0.003. No candidate was promoted.

Development remained 10/12 exact, 11/12 meaning, 10/12 context, 2/2 vocabulary, 11/11 safety,
and 23/23 runtime. The same vocabulary-spelling and emoji-adjacent cases fell back to raw.
Spelling scored 28/32 exact, position 22/32 exact/meaning, and the older physical-object cases
5/8 exact and 6/8 meaning. Blue-envelope and green-basket references were still changed into names.

The prospective novel-name probe improved to 30/32 exact/meaning, compared with composition's
8/32 exact and 25/32 meaning and context400's 20/32 exact and 26/32 meaning. Preservation passed
15/16 exact/meaning in each physical/application subgroup; it still changed a physical iron gate
into `IronGate` and missed one application normalization. Composition preserved all 16 physical
meanings but normalized only 9/16 application meanings; context400 passed 11/16 physical and
15/16 application meanings. These comparisons support a targeted benefit from the new data,
not release qualification. The experiment was rejected because development did not improve and
accepted meaning-changing replacements remain. The frozen release holdout is still unqueried.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/quant-recovery-qwen-4bit \
  --data Training/experiments/preservation-inputs \
  --resume-adapter-file Models/Artifacts/composition-qwen-adapter-v2/adapters/adapters.safetensors \
  --learning-rate 0.000003 --batch-size 2 --iters 600 \
  --steps-per-eval 100 --save-every 100 --adapter-path .build/preservation-adapters --test
```

## Canonical spelling contrast experiment

The [predeclared plan](experiments/canonical-copy-plan-2026-09-17.json) tests whether matched
supplied spellings improve literal vocabulary copying. The coverage audit found 239 training
vocabulary-positive records covering 120 normalized terms, with only one term appearing under
multiple canonical spellings. The [reviewed additions](experiments/canonical-copy-inputs/REVIEW.md)
cross eight existing terms with four spelling styles, two frames, and application/physical contexts.
All 960 previous records remain unchanged; the corpus now has **1024 train / 32 validation / 32 test**.
Validation and test files remain byte-identical. Casing, punctuation, and vocabulary slot are balanced.

The recipe retains the preservation experiment's starting composition adapter, base, learning rate,
batch size, seed, and 600 steps. Six checkpoints are ranked using the original native validation set
before running diagnostics and development evaluation. The new diagnostic contains four unseen
terms in 64 repeated spelling/frame/domain contrasts, not 64 independent terms. It cannot select a
checkpoint. Composition and preservation500 are controls on that diagnostic. Evaluation uses the
repaired optimized runtime, whose outputs matched debug for both controls in the paired comparison.

The [completed experiment](experiments/canonical-copy-2026-09-17.json) was rejected. Validation
exact scores were 25, 27, 30, 29, 31, and 31 out of 32. The predeclared meaning-first ranking
selected step 300: 32/32 meaning, 31/32 context, and 30/32 exact. Steps 500/600 each lost one
meaning-preservation case. All six passed safety/runtime. Final validation/test loss was 0.002/0.004.

Development remained 10/12 exact, 11/12 meaning, and 10/12 context. Spelling scored 27/32 exact,
position 22/32, older physical-object cases 4/8 exact and 6/8 meaning, and the earlier novel-name
probe 22/32 exact and 30/32 meaning. Accepted blue-envelope and green-basket name substitutions
remain. No candidate was promoted; the frozen release evaluation remains unqueried.

On the prospective canonical probe, exact accuracy was 33/64 and meaning preservation 47/64,
versus preservation500's 33/64 and 48/64. Application exact/meaning improved to 23/32 and 26/32
from 14/32 and 18/32, but physical preservation fell to 10/32 exact and 21/32 meaning from 19/32
and 30/32. Composition scored 16/64 exact and 41/64 meaning overall. The spelling contrasts
improved application normalization at the expense of ordinary-object preservation; they did not
produce a qualifying model. These small, repeated synthetic contrasts are diagnostic evidence.

A subsequent [training-fit diagnostic](experiments/canonical-training-fit-2026-09-17.json)
evaluated the 128 added training examples themselves at steps 300 and 600. Exact fit increased
from 92/128 to 114/128. Application meaning improved from 44/64 to 59/64, while physical-object
meaning fell from 63/64 to 57/64. Nine physical examples fell back at step 300; none did at 600.
Thus incomplete training fit remains, and better total fit still trades away physical preservation.
This post-hoc diagnostic cannot reselect a checkpoint or establish held-out quality. The original
selection remains step 300 and the experiment remains rejected.

The [runtime comparison](experiments/canonical-runtime-parity-2026-09-17.json) confirmed identical
training/native message bytes, prompt token counts, and greedy Python/Swift outputs on all 128
examples at step 600. The [batch reconstruction](experiments/canonical-training-exposure-2026-09-17.json)
matched all 60 logged cumulative token counts: at step 300, 54 added examples had zero exposures
and 74 had one; at step 600, 114 had one and 14 had two. The pinned `CacheDataset.itemlen` reads
the raw record's dictionary length, so all these chat records tie and pairs follow corpus order
before shuffling. An earlier local audit assuming token-length sorting was invalidated by this
check. These findings support testing additional exposure, without attributing all errors to it.

The [bounded continuation plan](experiments/canonical-continuation-plan-2026-09-17.json) starts
from the unpromoted step-600 adapter for 1,200 additional steps on the unchanged data, at the
same learning rate, batch size, rank, and layer count. It restarts optimizer state. Six checkpoints
at 200-step intervals use the original validation ranking before any diagnostic/development
evaluation; the existing quality and preservation requirements remain unchanged. This is a
continuation experiment, not an uninterrupted-run equivalence claim.

The [completed continuation](experiments/canonical-continuation-2026-09-17.json) was rejected.
Validation exact scores at the six additional-step checkpoints were 31, 29, 32, 32, 31, and 31
out of 32; all passed meaning, safety, and runtime checks. Additional steps 600 and 800 tied on
the ranking and logged loss, so the earlier step 600 was selected before diagnostics. Final-step
test loss was 0.005.

The selected candidate fit 126/128 added training examples exactly, improving on the starting
checkpoint's 114/128. It passed all eight older physical-object cases, but development stayed
at 10/12 exact and 11/12 meaning. Spelling scored 27/32 exact, position 17/32, and the earlier
novel-term probe 29/32. The canonical diagnostic improved to 45/64 exact and 49/64 meaning:
application cases scored 21/32 exact and 22/32 meaning; physical cases scored 24/32 and 27/32.
Seven physical cases still received accepted vocabulary substitutions, including casing changes
that the case-insensitive meaning metric cannot detect. The earlier novel probe also retained
an accepted physical `IronGate` substitution. Better training fit did not produce a qualifying
model; no candidate was promoted and the frozen release evaluation remains unqueried.

## Larger stock-model feasibility check

The [isolated preparation](experiments/qwen-2b-preparation-2026-09-17.json) downloads
[Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) at revision
`15852e8c16360a2fea060d615a32b45270f8a8fc` under Apache-2.0 and converts it with the locked MLX
environment to four-bit affine/group-64 weights. Official file sizes and available LFS hashes
are checked; downloaded and converted inventories are retained. Production metadata is unchanged.

The [fixed native comparison](experiments/qwen-stock-size-2026-09-17.json) runs the stock 0.8B
and 2B models on the same 32 validation and 64 previously observed canonical cases, each with
11 adversarial cases. Both score zero exact plans and fall back on every request. This proves
the existing runtime can execute the larger artifact, not a trained-model quality advantage.
The stock 0.8B files match the earlier retained stock baseline. All four runs pass native safety
and runtime-consistency checks.

Observed 2B peak physical footprints were 1.976 GB and 2.039 GB in the two Cleanup-only processes
on the M5 Pro. These failed stock generations do not measure successful trained Cleanup latency,
full Dictation memory, or physical M1 behavior. A task-specific training experiment would be needed
before drawing a quality comparison. ADR 0039's shipping model decision and all release gates remain
in force; a larger development artifact is not an approved replacement.

Full verification passed:
root and all six package suites, optimized Cleanup, 39 Python tests, and 3821 repository checks.
The training preflight validates every chat mask and finds a maximum sequence length of 427 tokens.

## Fresh 2B training result

The [frozen protocol](experiments/qwen-2b-training-plan-2026-09-17.json) trains a fresh
rank-8 adapter on the stock four-bit 2B base for 2,048 steps, using the existing
1,024 training, 32 validation, and 32 test records. It retains separate base and adapter
weights. Eight checkpoints receive native validation; safety/runtime eligibility and
meaning, context, exact, loss, then earlier-step ranking determine selection before the
existing diagnostics and development evaluation. Exported model inventories must remain
identical across every invocation, including the selected-model training-fit check.

The [completed result](experiments/qwen-2b-training-2026-09-17.json) selected step 1,024
before diagnostics. The eight native validation exact scores were 12, 26, 28, 31, 30, 30,
30, and 29 out of 32. The selected checkpoint preserved meaning and context on all 32
validation cases; all checkpoints passed 11 safety and 43 runtime checks.

Development passed 12/12 exact, meaning, and context checks, 2/2 applicable vocabulary
checks, 11/11 safety, and 23/23 runtime checks. This is the first retained candidate to pass
all development cases, but it does not qualify under the broader preservation gates:

| Existing diagnostic | Exact | Meaning |
| --- | --- | --- |
| Canonical | 49/64 | 59/64 |
| Novel terms | 23/32 | 26/32 |
| Earlier physical cases | 8/8 | 8/8 |
| Position | 30/32 | 30/32 |
| Spelling | 30/32 | 32/32 |
| Added training examples (not held out) | 122/128 | 123/128 |

Canonical application cases passed 32/32 exact; physical cases passed 17/32, with seven
accepted vocabulary substitutions and eight duplicate terminal periods. Novel application
cases passed 16/16; physical cases passed 7/16, with seven accepted vocabulary substitutions,
one fallback, and one duplicate period. Two canonical substitutions and one novel substitution
only changed casing, so the case-insensitive meaning metric missed them. These errors reject
the candidate despite its development score.

Development Cleanup-only timing on the M5 Pro was p50 506 ms and p99 902 ms, including the
first request's kernel warmup. Peak physical footprint was 2.734 GB. These observations do
not establish full Dictation latency/memory or physical 8 GB M1 performance.

This experiment reused diagnostics and differs from smaller-model runs in more than model
size. It is not an independent release estimate or controlled capacity comparison. No model
was promoted, and ADR 0039, production metadata, release criteria, and the untouched release
evaluation remain unchanged. Shipping a larger model requires revisiting the model decision.

```sh
.build/training-venv/bin/python Training/train.py \
  --config Training/config/lora.yaml --model Models/Artifacts/baseline-qwen-2b-4bit \
  --data Training/experiments/canonical-copy-inputs \
  --learning-rate 0.00001 --batch-size 2 --iters 2048 \
  --steps-per-eval 256 --save-every 256 --adapter-path .build/qwen-2b-training-adapters --test
```

## Broader object contrasts

The [reviewed isolated data](experiments/diverse-objects-inputs/REVIEW.md) adds 512 training
examples across 32 new terms, preserving the original corpus and generated chat prefix.
The experiment has 1,536 training records; validation and test files remain byte-identical.
An additional 128-case diagnostic covers eight other terms and is excluded from training
and checkpoint selection. Target/distractor styles, vocabulary order, sentence mechanics,
and application templates are balanced to avoid the shortcuts found during review.

The [frozen continuation protocol](experiments/diverse-objects-plan-2026-09-17.json) starts
from the unpromoted 2B step-1,024 adapter. It uses 1,536 additional steps at learning rate
0.000003 with a fresh optimizer and six checkpoints. Unchanged native validation selects
the artifact before six diagnostics, development, and the 512-example training-fit check.
The unchanged parent then runs the new diagnostic as a control. All original acceptance
gates remain, including preservation of physical references; the new diagnostic must also
reach 95% exact and 100% meaning/context/vocabulary/safety/runtime before qualification.

Both data reviews, native label/prompt agreement for all 1,728 records, and training
preflight passed. The [completed result](experiments/diverse-objects-2026-09-17.json)
selected additional step 768 before diagnostics. It reached 31/32 exact with perfect
meaning/context on native validation and fit all 512 added training examples exactly.
The independent 128-case diagnostic improved from the unchanged parent's 61 exact to 117,
with 123 meaning and 128 context passes. It still missed the 95% exact and 100% meaning
gates. Development also regressed to 11/12 exact and 11/12 context, while position,
spelling, and the prior physical diagnostic passed completely. Canonical and novel probes
still contained six accepted physical-name substitutions, including casing-only changes the
meaning metric does not catch. The candidate is rejected; production corpus, ADR 0039,
model metadata, and frozen release inference remain unchanged.

A fixed [prompt-only diagnostic](experiments/semantic-vocabulary-instruction-2026-09-17.json)
then clarified that vocabulary entries are optional named-application spellings. It preserved
safety/runtime and the already-perfect position/spelling suites, but canonical exact/meaning
fell from 59/61 to 56/58 and the diverse diagnostic fell from 117/123 to 115/119. Development
remained 11/12 exact/context. The prompt variant is rejected without a production change.

## Focused context continuation

The [reviewed focused data](experiments/diverse-contexts-inputs/REVIEW.md) adds 1,024
training-only contrasts across 32 new terms and four physical/application frames. A separate
256-case prospective diagnostic covers eight other terms. Review removed an overlapping term
and two conditional distractor/slot shortcuts before inference. All 1,280 labels passed native
Swift agreement, and the tokenizer preflight validated 1,024/32/32 chats with a 407-token maximum.

The [frozen protocol](experiments/diverse-contexts-plan-2026-09-17.json) resumes the rejected
step-768 adapter for 1,024 steps at learning rate 0.000002, using only the new training records.
Eight checkpoints are selected solely by the unchanged 32-case native validation and safety set.
The selected artifact then runs the prospective diagnostic, every retained regression, development,
new and prior training-fit checks, and a parent control. Both protocol reviews are clear.

The [completed result](experiments/diverse-contexts-2026-09-17.json) selected step 128 before
diagnostics. The prospective suite reached 250/256 exact, 251 meaning, and 255 context; the retained
diverse suite reached 127/128 exact/meaning, and canonical, novel, physical, position, and spelling
passed completely. Development regressed to 10/12 exact/context. Five prospective physical cases
received accepted name substitutions, including one casing-only change missed by meaning; new
training-fit also retained one casing-only substitution. The candidate is rejected. No model was
promoted, and the frozen release suite remains unqueried.

## Context adapter blend check

The [validation-only blend comparison](experiments/context-blends-2026-09-17.json) exactly
interpolated the retained diverse-object and focused-context adapters at 25%, 50%, and 75% child
weight. The 25% blend tied its parent at 31/32 validation exact with perfect meaning and context;
the other blends scored 29/32 exact. Because no blend strictly improved the parent, the frozen gate
selected none. Independent [review](experiments/context-blends-review-2026-09-17.json) verified the
tensor interpolation and result identities.

A separately reviewed protocol amendment allowed the fixed 25% blend to run only already-observed
regressions as a cost check. The [completed feasibility result](experiments/context-blend-feasibility-2026-09-17.json)
scored 11/12 development exact, 219/256 context-diagnostic exact with 226/256 meaning, 62/64 canonical
exact with 63/64 meaning, and 125/128 diverse exact with 127/128 meaning. It also accepted 29 physical
name substitutions in the context diagnostic and two in canonical. It therefore stops without a new
prospective diagnostic, promotion, or frozen release query.

## Mixed rehearsal recovery

The [reviewed recovery protocol](experiments/rehearsal-recovery-plan-2026-09-17.json) resumed the
focused-context step-128 adapter at learning rate 0.000001. Its 2,048-record train split equally
interleaved the retained pre-context corpus and focused-context additions. Development and the
unchanged 32-case validation set selected among eight checkpoints before broader observed regressions.

The [completed result](experiments/rehearsal-recovery-2026-09-17.json) selected additional step 128.
Development improved to 11/12 exact/context with perfect meaning, and canonical, diverse, physical,
position, and spelling suites passed completely. Equal replay nevertheless reduced the focused-context
diagnostic to 198/256 exact and 212/256 meaning, with 46 accepted physical-name substitutions. The
experiment is rejected without prospective or frozen release inference or promotion. The result's
post-run audit correction accounts for all eight legacy physical-suite rows despite their older
`irrelevant` coverage tag; all eight were exact and contained no vocabulary substitution.

## Targeted mechanics repair

The [reviewed mechanics protocol](experiments/mechanics-recovery-plan-2026-09-17.json) resumed the
focused-context step-128 adapter for 128 steps at learning rate 0.0000005. Its 384 training records
combine 128 new capitalization-and-period examples with 256 byte-preserved context replays. Review
counterbalanced style, frame, distractor style, domain, and vocabulary position before training.

The [completed result](experiments/mechanics-recovery-2026-09-17.json) selected step 64. Although it
fit all 128 mechanics examples, development fell to 9/12 exact and the focused-context diagnostic
reached only 227/256 exact and 234/256 meaning. The repair is rejected without prospective or frozen
release inference or promotion. This shows that narrow mechanics training still overwrites broader
behavior and does not justify another continuation with the same recipe.

## Original-to-context adapter interpolation

Three reviewed screens interpolated the development-perfect original 2B adapter with the strongest
focused-context adapter. Context weights 90%, 95%, and 97.5% all remained at 10/12 development;
25%, 50%, and 75% reached 11/12. The final 5%, 10%, and 20% bracket found that 5% and 10% both
restore 12/12 development and 31/32 validation exact, so the frozen higher-child tie-break selected
10%. See the [high](experiments/high-context-blends-2026-09-17.json),
[mid](experiments/mid-context-blends-2026-09-17.json), and
[low](experiments/low-context-blends-2026-09-17.json) results.

The separate [known-regression feasibility check](experiments/low-blend-feasibility-2026-09-17.json)
rejected that selected blend. It scored 173/256 context meaning with 75 accepted physical word
substitutions, 61/64 canonical meaning, and 94/128 diverse meaning. The category-independent audit
compares physical output words case-sensitively with expected wording, catching capitalization edits
as well as vocabulary-category substitutions. No prospective or frozen release fixture was queried.

## Direct focused-context continuation

The [reviewed direct protocol](experiments/direct-context-plan-2026-09-17.json) bypassed the earlier
diverse-object continuation and trained the development-perfect original 2B adapter directly on the
focused-context corpus for 128 steps. Development, focused contexts, and unchanged validation selected
among four checkpoints before the known regression suites.

The [completed result](experiments/direct-context-2026-09-17.json) selected step 96. Canonical passed
64/64, diverse reached 124/128 exact and 126/128 meaning, and novel reached 31/32 exact/meaning. The
physical, position, and spelling suites passed completely. Development still missed its emoji case at
11/12 exact/context, while the focused-context diagnostic reached 199/256 exact and 214/256 meaning
with 31 accepted physical-word substitutions. Independent reviews confirmed the result and rejection.
No prospective or frozen release fixture was queried, and no model was promoted.

## Complementary repair-vector screen

The [reviewed local grid](experiments/repair-vector-grid-plan-2026-09-17.json) added 10%, 20%, or
30% of both the rehearsal and mechanics adapter deltas to the strongest focused-context adapter.
The two source continuations had repaired different development failures, so this cheaply tested
whether their task vectors combined without more training.

The [completed result](experiments/repair-vector-grid-2026-09-17.json) found no eligible candidate.
All nine combinations scored 29/32 validation exact and 10/12 development exact/context. Tensor
arithmetic, all 18 evaluations, and the null selection passed independent review. This exhausts the
tested parents and weights for the current development objective. No broader, prospective, or frozen
release fixture was queried, and no model was promoted.

The follow-up [early-checkpoint replay](experiments/early-rehearsal-2026-09-17.json) measured the
previously unsaved steps 8 through 56 of the unchanged rehearsal recipe. Step 48 won the frozen
ranking but remained at 11/12 development exact/context. Focused contexts fell to 193/256 exact and
209/256 meaning with 47 physical-word substitutions. Independent review confirmed all seven
checkpoints and 21 evaluations. The sampled early interval is rejected without a prospective or
frozen release query or promotion.

## Joint 0.8B training

The [frozen joint protocol](experiments/joint-08b-plan-2026-09-18.json) trained one fresh
adapter on all 2,688 reviewed original, diverse-object, focused-context, and mechanics chats.
The original process saved every checkpoint and the final adapter, then received `SIGBUS` during
trainer shutdown before printing test loss. The [reviewed recovery protocol](experiments/joint-08b-recovery-plan-2026-09-18.json)
verified every saved tensor and identity, recomputed test loss with the same model, tokenizer,
data, masking, and batch recipe, and ran the unchanged native selection and diagnostics.

The [completed recovered result](experiments/joint-08b-2026-09-18.json) selected step 2,016
using validation only: 31/32 exact and 32/32 meaning/context, with all safety and runtime checks.
Canonical and novel diagnostics passed completely. The focused-context diagnostic reached
233/256 exact and 240/256 meaning, including ten accepted physical-name substitutions.
The diverse diagnostic reached 124/128 exact and 127/128 meaning; development reached only
8/12 exact and 10/12 meaning. Position and spelling were 31/32 and 30/32 exact. The candidate
fails the frozen gate and is rejected without promotion or release inference. The retained local
audit at `.context/joint-08b-result-audit-2026-09-18.json` verifies result integrity; independent
completion review remains required.

## Practical MVP candidate

ADR 0054 supersedes the original 0.8B model choice. The retained
[candidate decision](experiments/practical-candidate-decision-2026-09-18.json) selects
`Models/Artifacts/diverse-contexts-step128`, a separate F32 adapter on the pinned four-bit Qwen
3.5 2B base. Across the observed development and regression suites it reaches 555/564 exact plans,
558/564 meaning preservation, and 561/564 context fit; every adversarial and runtime check passes.

Five of 128 focused physical-object cases receive unwanted vocabulary substitutions. Development
also contains one missed capitalization/punctuation cleanup and one safe raw fallback. These known
residuals are retained as post-MVP iteration work. No further training run is planned. The candidate
was then queried once against frozen `release-v2`: 48/48 meaning, 4/4 applicable vocabulary, 22/22
adversarial safety, and 70/70 runtime consistency passed; delivered text matched 38/48. The strict
release gate failed at 32/48 exact plans and 44/48 context fit. The result is retained in
[`practical-candidate-release-v2-2026-09-18.json`](experiments/practical-candidate-release-v2-2026-09-18.json).
No holdout-driven retraining or threshold change is planned. Physical 8 GB M1, signed Model Pack
capture, and distribution smoke remain required before release qualification.
