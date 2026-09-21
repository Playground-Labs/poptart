# Vocabulary position additions — September 17, 2026

These 144 authored synthetic, CC0 examples extend the fixed 624-record boundary corpus.
All additions are train-only. The resulting split is 704 train, 32 validation, 32 test;
validation and test bytes remain unchanged. No release holdout was queried by a model.

The intervention follows the native vocabulary spelling and position diagnostics. It adds
128 vocabulary edits, 16 at each start position zero through seven, and 16 no-op examples
preserving already-correct names. Two sentence frames per position cross the spelling styles.
All examples contain two vocabulary entries; target order varies in both positive and no-op
examples. Application context disambiguates names that can also refer to physical objects.

Independent agent reviews by `comparison_spec` and `comparison_standards` initially found:

- Four normalized duplicate no-op utterances.
- A vocabulary-list-length shortcut distinguishing positive examples from no-ops.
- Ambiguous physical-object readings for Work Bench.
- Only one sentence frame per ordinal position.

The revised wording, distractors and second frames resolve those findings. Both reviewers
independently checked all 768 prospective records with the unchanged corpus builder and overlap
checker against evaluation fixtures and reported no remaining actionable findings. This is
label/source review, not accuracy certification or a claim of representative generalization.

`additions.jsonl` retains the reviewed examples; `author_additions.py` records their authoring
procedure. The authoring script writes `.context/position-additions.jsonl` when run from the
repository root; create `.context` first if reproducing that optional authoring step. Training
uses the frozen chat files directly. No original corpus record or held-out label was changed.
