# Frozen holdout review — approval withheld

This is an author-side audit of the frozen 48 gold and 22 adversarial cases. It is
not the independent review required by `manifest.json`; that field remains null.
No model has been evaluated on this holdout. The fixture bytes remain unchanged.

All gold outputs and reserved corrections pass the native Swift validator/applier.
The text was reviewed against the intended category, context, and vocabulary.
Training preparation rejects direct normalized overlap with the holdout.

An independent reviewer should resolve these policy questions before acceptance:

- **Equivalent plans:** repeated-word deletion can target either copy and produce
  the same correct text. Exact-plan scoring deliberately distinguishes those plans.
  Confirm that 95% exact plans is an appropriate release criterion, or version the
  policy and labels to recognize explicitly approved alternatives.
- **Allowed adversarial outputs:** most cases enumerate unchanged text, a terminal
  period, and capitalization plus a period. Capitalization alone can also be safe
  but is not enumerated. This is a conservative false-failure risk, not evidence of
  unsafe behavior. A label expansion requires a new frozen suite version.
- **Unicode policy:** hidden/control-character fixtures require a rejected plan
  and unchanged raw fallback. The runtime now applies its existing strict scalar
  policy to the original transcript as well as replacements. Newlines, tabs, and
  emoji/language joining characters also take this fallback; no text is stripped.
  Confirm this conservative behavior before accepting the policy. It is not input
  sanitization, and the raw fallback may still contain those characters.
- **Coverage and uncertainty:** the longer cases are still short compared with a
  five-minute Dictation; their labels make minimal edits to existing comma splices.
  The preservation set is small, and synthetic text does not represent recognition
  errors, accents, microphones, or prosody. Review semantic/template overlap, not
  just duplicate strings. Passing these counts is not a statistical production
  quality guarantee.

Record the independent review, including any required new suite version, using
the review scope hash and fields documented in `Evals/README.md`. Automated checks
and this author audit must not be entered as that independent approval.


## Standards

Independent code review on September 16, 2026 found a startup/unload race in the MLX adapter:
generation startup could suspend before registering the task, allowing teardown to miss it.
The lifecycle gate now covers startup/registration and teardown; streaming completion stays
outside the gate so cancellation can join it. The reviewer checked the queued-cancellation,
unload, and gate-reuse regression test and reported no remaining substantive Standards findings.

## Spec

Independent review withheld frozen-label approval. Two release-verifier findings were fixed
and re-reviewed: candidate archive payloads are bound to evaluated model identities, and updates
must compare against an identified shipped predecessor under the current trusted evaluator.
The reviewer confirmed both fixes within the documented trusted-input boundary; retained binary,
source/scorer, fixture, shipped configuration, and archive hashes must agree.

Two suite findings remain open: safe capitalization-only adversarial outputs are missing from
allowlists, and malformed/overlapping span probes need native execution evidence separate from
ordinary model inference. Current Python probe checks and valid-plan corpus tests do not establish
that native probe coverage. Resolve these in a newly versioned suite; do not edit frozen v1 bytes
or record independent approval yet. Exact-plan equivalence and benign Unicode fallback also need
explicit policy acceptance as described above.

Standards: no unresolved findings. Spec: two unresolved suite findings; release approval withheld.
This records independent agent review, not human release sign-off or a security certification.
