# Control-character corruption guard

Completed 2026-10-18; artifacts retain the run's starting-date directory.

**Fixed:** the preferred 4-bit model's accepted `Hello\u0007.world` edit now
returns the exact raw `hello\u0007world` instead. In the full 79-case rerun,
only `adv-control` changed; all other outputs and outcomes were identical.
Non-adversarial exact outputs remain 49/68 with no new regressions.

## Cause and policy

The validator previously checked only replacement text for unsafe control
characters. A plain period passed that check even when inserted beside an existing
BEL character. The tokenizer and applier were correct: the minimal plan inserted
at the requested boundary in `a\u0007b`, producing `a\u0007.b`.

Swift and the Python mirror now reject nonempty model plans when the raw transcript
contains a Unicode control scalar outside Foundation's whitespace/newline set.
This deliberately forgoes model cleanup of such inputs rather than guessing at
ambiguous boundaries. It does not strip or sanitize the original text. Empty
model plans remain allowed; deterministic corrections retain their existing rules.
Ordinary whitespace (including tabs, CR/LF and NEL) and joined emoji remain eligible
for cleanup. Format characters such as emoji joiners are not classified as controls
by this guard; this is not a blanket Unicode prohibition.

## Evidence

The exact saved generation was added as a regression in both the Swift Cleanup
engine and Python evaluator. Both failed before the fix (the result was cleaned
instead of raw fallback), then passed after the validator and mirror changed.
Additional tests cover NUL, BEL, ESC, unit separator, DEL and CSI; empty plans;
spaces, tabs, line breaks, NEL, Unicode line separator and joined emoji.

```sh
python3 -m unittest Scripts/test_tooling.py
swift test --package-path Packages/Cleanup
```

20 Python tests and 23 Swift tests pass. `git diff --check` passes. No model or
prompt changes were made. The preferred weights remain
`.context/cleanup-round9/step-200/candidate-4bit`, with hashes in the referenced
round-nine artifact manifest.

`predictions.jsonl` contains the full real-model 79-case rerun against the same
fixtures as round nine. `comparison.json` validates complete coverage and compares
saved before/after results using the existing scorer. `control-recheck.jsonl`
records an additional one-case native process that returned raw fallback and
exited 0. `verification.json` records source and fixture hashes.

The strict adversarial fallback count moves from 5/11 to 6/11. The other five
accepted adversarial outputs are unchanged from the previous review and only
capitalize initial text and/or add a final period. This is a bounded observation,
not a blanket safety qualification. The remaining nineteen incorrect ordinary
outputs, existing model regressions, and physical 8 GB M1 benchmark still prevent
launch qualification. No release metadata was populated or weights published.
