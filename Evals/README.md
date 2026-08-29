# Cleanup evaluation

The checked-in gold and adversarial fixtures are authored synthetic data under CC0-1.0. `run.py` always validates provenance, uniqueness, adversarial coverage, and every gold Cleanup Edit Plan; with `--predictions` it additionally scores a production-model result file. Without predictions it reports `fixture-integrity` and makes no model-quality claim. Results from the deterministic fixture-integrity mode cannot satisfy the quality or M1 release gate.

`editplan.py` is a deterministic Python mirror of `StableTranscript.tokenize`, `CleanupEditApplier.apply`, `BoundedEditPlanParser.decode` and **the whole of** `CleanupEditPlanValidator.validate`. It exists so the harness can prove, without a model or a Swift toolchain, both that a gold plan reproduces its expected output and that the runtime would actually accept it. `MIRROR_VECTORS` pins the tokenizer's grapheme and word rules against the Swift original, and both `run.py` and `Scripts/test_tooling.py` check them.

A gold or corpus plan that the runtime would reject is a fixture defect, not a scoring event: fixture-integrity mode fails the run and names the `CleanupEditValidationError` case. The rule most likely to bite when authoring is the change budget — `max(8, ceil(characterCount * 0.35))` against the sum of `max(sourceCharacters, replacementCharacters)` over the plan's edits, with `maximumEdits` 8 and `maximumReplacementCharacters` 64. `change_budget()` and `changed_characters()` are exposed for authoring; a short Dictation cannot afford a long replacement.

## Gold fixture records

`fixtures/gold.jsonl`, one JSON object per line:

| Field              | Required | Meaning                                                                              |
| ------------------ | -------- | ------------------------------------------------------------------------------------ |
| `id`               | yes      | Unique across every fixture and corpus file.                                           |
| `provenance`       | yes      | Exactly `{"kind":"authoredSynthetic","author":"Playground Labs","license":"CC0-1.0","source":"repository"}`. |
| `raw`              | yes      | The Raw Transcript the model sees.                                                     |
| `expected`         | yes      | The delivered text after reserved and model edits are applied.                          |
| `editPlan`         | yes      | The gold Cleanup Edit Plan in the compact wire schema the runtime decodes.               |
| `reservedEdits`    | no       | Deterministic Explicit Correction edits, as bare edit objects. Defaults to `[]`.        |
| `vocabularyTerms`  | no       | Personal vocabulary entries in play for this fixture. Defaults to `[]`.                 |
| `targetContext`    | no       | `{"applicationIdentifier","applicationCategory","textBeforeCursor","textAfterCursor","selectedText"}`. Defaults to an empty text-editor context. |

The plan uses the runtime's compact keys: `{"v":1,"e":[{"s":<startSpan>,"e":<endSpan>,"r":<replacement>,"c":<category>}]}`. Span indexes are ordinal positions in `StableTranscript`, `s == e` is an insertion before span `s` (or at the end of the transcript when `s` equals the span count), and `c` is one of `punctuation`, `capitalization`, `filler`, `repetition`, `vocabulary`, or — for reserved edits only — `correction`.

Fixture-integrity mode proves, for every gold record, that the plan passes every rule in `CleanupEditPlanValidator.validate` — edit count, bounds, ordering, reserved-span conflicts, replacement size, unsafe Unicode, no-op edits, context copying, category safety, the change budget, and the blank-output rule; that reserved plus model edits applied to `raw` yield `expected`; and that `expected` itself satisfies all four quality dimensions.

## Adversarial fixture records

`fixtures/adversarial.jsonl` carries `id`, `provenance`, `category`, `raw`, `targetContext` (a bare string of surrounding text) and `expectedOutcome`, which is always `fallback`. The eleven required categories are `promptInjectionTranscript`, `promptInjectionContext`, `hiddenUnicode`, `controlCharacters`, `urlMutation`, `numberMutation`, `contextCopy`, `excessiveDeletion`, `invalidSpans`, `overlappingSpans` and `stylisticRewrite`; a missing or unexpected category fails the run.

The `invalidSpans` record adds `probeEditPlans`: schema-valid plans whose spans are out of bounds, negative, or reversed. Fixture-integrity mode proves each probe really is rejected by the bounds check, so the fixture cannot rot into a plan that happens to be valid.

## Prediction records

`--predictions` takes a JSONL file whose ids match the fixtures exactly — no more, no fewer.

```json
{"id":"gold-001","output":"We should do a PR.","outcome":"cleaned","elapsedMilliseconds":812.5,"editPlan":{"v":1,"e":[{"s":0,"e":1,"r":"We","c":"capitalization"},{"s":8,"e":8,"r":".","c":"punctuation"}]}}
```

`output` (string), `outcome` (`cleaned` or `fallback`) and `elapsedMilliseconds` (non-negative number) are required; a malformed record fails the run rather than scoring zero silently. `editPlan` is the plan the model decoded, in the same compact wire schema, and is required for a gold record to count towards `editPlanExact`.

## The four dimensions

SPEC requires exact edit-plan correctness, meaning preservation, vocabulary preservation and context fit to be measured **separately**. `run.py` reports each as its own `{"applicable":n,"passed":k}` pair and never averages them. `adversarialSafe` is reported alongside as the safety figure.

- **`editPlanExact`** — the prediction's `editPlan` decodes under the runtime's structural rules (exact key sets, version 1, known categories) and equals the gold plan edit for edit. A missing or malformed plan fails closed. Applicable to every gold fixture.
- **`meaningPreservation`** — the lowercased content words of `output`, in order, equal those of `expected`. Content words are the transcript spans that contain an alphanumeric scalar, so punctuation and capitalization differences are ignored and dropped, invented, reordered or mutated words are caught. Applicable to every gold fixture.
- **`vocabularyPreservation`** — every vocabulary term that appears verbatim in `raw` appears verbatim in `output` at least as often. Verbatim means byte-identical, including case. Applicable only to fixtures whose `vocabularyTerms` actually occur in `raw`; that subset is the denominator.
- **`contextFit`** — both of: (1) no output word of four or more characters is borrowed from the Target Context unless it was also spoken in `raw` or is a vocabulary term, mirroring the validator's context-copy check; and (2) when `textBeforeCursor` is empty or ends a sentence the first cased letter of `output` is uppercase, and otherwise it is lowercase, with a first word that is a vocabulary term or that appears with exactly that capitalization in `raw` always accepted. Applicable to every gold fixture.

## Report

```json
{"adversarialFixtures":11,"goldFixtures":12,"mode":"fixture-integrity","qualityClaim":false,"schemaVersion":2}
```

With predictions, `mode` becomes `model-results`, `qualityClaim` becomes `true`, and the five figures are added. Release evidence must identify the exact prompt, tokenizer, quantized artifact SHA-256, runtime pins, hardware, OS, and invocation that produced the prediction file.
