# Span/context diagnosis: instruction-only changes rejected

Decision: keep the production prompt and the retained round-nine model unchanged.
This is a bounded diagnostic on the **rejected balanced step-80 weights**, not
another training run or a qualification of those weights. No combined suffix or
revised prompt was tried after seeing results.

## Reproduction and hypotheses

`python3 Training/runs/2026-10-20-span-context/replay.py --require-correct`
replays three captured native punctuation failures through the Python mirror and
exits 1, deliberately demonstrating the failed output assertion. Without the flag
it exits 0 after checking that the captured output reproduces and that changing
only the insertion boundary from 6 to 7 yields the expected text. The three raw
sentences each contain seven spans. The applier is applying the supplied boundary
as specified; the model chose the wrong boundary. The validator accepts this
punctuation-only edit, so category safety alone does not guarantee correct layout.

Before inference, the hypotheses were frozen in `protocol.json`:

1. Explicit exclusive-end and end-of-transcript instructions could reduce boundary errors.
2. A learned position preference could persist despite instructions and depend on length.
3. Explicit cursor-context instructions could reduce inappropriate capitalization.

The native evaluator gained an optional local system-suffix file, used only by
this development executable. It applies the identical transformed request to
both token counting and generation, and records the full system instruction in
predictions. Default invocation preserves the existing instruction. No app
boundary, parser, validator, applier, corpus, or training target was changed.

## Frozen comparison

Twenty-four new authored synthetic fixtures cover six statements at 3/7/11 spans,
four filler cases, four repetition cases, and five paired mid-sentence/new-sentence
contexts. The pairs intentionally share raw text; only their cursor context and
expected initial case differ. Raw inputs were checked against canonical training
and evaluation fixture directories. They are diagnostic examples, not a new
representative release benchmark.

| Exact output | Current prompt | Boundary suffix | Context suffix |
| --- | ---: | ---: | ---: |
| Statements /6 | 5 | 4 | 4 |
| Filler /4 | 2 | 2 | 2 |
| Repetition /4 | 4 | 4 | 4 |
| Mid-sentence /5 | 0 | 0 | 0 |
| New sentence /5 | 5 | 5 | 5 |
| Total /24 | **16** | **15** | **15** |

Both suffixes lose `diagnostic-00` ("I bought pears"). The boundary suffix
produces "I bought .pears"; the context suffix produces an invalid response and
falls back to raw. Neither fixes the seven-span "I hid ... cushions" case or the
two empty filler-deletion spans. All three arms produce identical outputs across
each context pair, incorrectly capitalizing all five mid-sentence continuations.
The actual payloads contain the differing contexts; this is not a fixture-loader
omission. Output and input-token checks confirm both suffixes reached inference.

Neither intervention meets the frozen requirement: higher total exact output,
no loss of a previously correct output, and targeted-group improvement. Exact
output is the diagnostic metric; these fixtures do not carry gold edit plans,
so the scorer does not report a fabricated edit-plan-exact metric.

## Interpretation and next useful experiment

The cheap instruction-only fix failed. This small sample supports sensitivity to
span positioning and poor context response in this checkpoint. It does **not**
prove that the model always predicts index 6: three- and eleven-span statements
also succeed, and the boundary suffix causes a new index-2 error. It does not
establish the causal role of fine-tuning, identify a universally safe output repair,
or establish behavior on the retained round-nine model.

Do not infer intended edits from the failed indices or silently repair them in the
runtime. The next distinct experiment should compare the current range-based
output with a typed operation representation that makes terminal punctuation and
single-token deletion explicit and compiles them deterministically to the existing
validated plan. Freeze a separate protocol, train/evaluate both representations
with matched data/budgets, include paired context examples, and preserve all
existing safety/retention gates. This needs a prototype and measured evidence;
it is not an approved production schema/ADR change. More repeats of the same
continuation or prompt wording are not supported by this diagnostic.

## Verification and reproduction

From repository root, `evaluate.sh` runs the three native arms and `score.py`
validates complete prediction IDs, unchanged user payloads, exact system suffixes,
increased input-token counts, and frozen selection criteria. Existing output
files prevent accidental overwriting; use new paths to reproduce inference.
`test_score.py` checks a synthetic positive control, a regression, and missing
predictions. `prepare.py` records fixture generation; do not rerun it over evidence.

Cleanup tests: 23 passed. Root app integration: 87 passed. Python tooling/release
suite: 26 passed. Three native runs produced 24 records each, exit 0. Four
previously captured cases were additionally replayed natively without a suffix to
check default invocation compatibility. Detailed results and hashes are recorded
in `verification.json`. Diagnostic deadlines are 30 seconds, not release latency.
No training, GPU rental, model promotion, M1 measurement, or release qualification
was performed.
