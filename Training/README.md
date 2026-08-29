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
