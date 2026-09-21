# Release v2 review

Status: accepted by independent agent review on September 16, 2026; not approval to ship. No trained model has been queried on v1 or v2.
Version 1 remains unchanged. Version 2 inherits its 48 gold utterances and labels, assigns
versioned IDs, and revises the 22 adversarial records before candidate evaluation.

Changes requiring review:

- Add capitalization-only outputs wherever safe no-op/punctuation variants already exist.
- Replace literal backslash-u text in two control-character fixtures with actual U+0007 and U+001B scalars.
- Add native rejection probes: six invalid-bound plans, six overlapping/unordered/duplicate-insertion
  plans, and four no-op plans over hidden/control text. The validator must identify the intended
  error; the production parser/engine must fall back to byte-identical raw text.
- Keep native probe evidence separate from generated model predictions. Controlled model output
  proves boundary behavior, not learned resistance. Release verification requires complete probe
  IDs, expected errors, safe fallback contents, and finite timings in the retained native report.

The 95% exact-plan threshold is intentionally strict: equivalent repetition deletions can yield
correct text yet lose an exact-plan point. Other dimensions are measured separately and require
100%. This is an engineering candidate gate, not a statistical reliability claim. Six deterministic
correction examples are also checked against the native correction implementation by the corpus test.

The original-text Unicode policy deliberately falls back unchanged for all rejected scalar classes,
including benign newlines, tabs, and emoji/language joining scalars. It does not strip or sanitize
input. Native and mirrored policy tests cover those limitations; independent policy acceptance is
required before using this suite as release evidence.

These authored samples remain small and synthetic. Long examples are shorter than five-minute
Dictations. Topic/template overlap needs judgment beyond the automated duplicate exclusion.
A passing result would not establish representative speech quality, M1 performance, privacy,
security review, or distribution readiness.

## Standards

The independent Standards reviewer found no documented-standard violations or substantive
maintainability, trust, logic, or race issues. Probe coverage requires exact fixture/index IDs;
verification rejects missing/duplicate probes, wrong errors, changed raw text, invalid fallback
reasons, and nonfinite timings. Probe-only execution returns before constructing an MLX model,
and each controlled probe gets its own observer. No unresolved Standards findings.

## Spec

The independent Spec reviewer (`quality_spec_review`) read all 48 gold and 22 adversarial
records and accepted labels, allowed outputs, coverage, leakage assessment, and threshold policy.
Reviewed scope digest: `10f5333248bb293597b49b6813a594b8df3c5e56802bfe3ab43db861ff90dc62`.

The reviewer confirmed actual U+0007/U+001B scalars, conservative gold edits, safe capitalization
variants, and separate native probe verification. They explicitly accepted the strict 95% exact-plan
gate and 100% remaining dimensions as finite-suite criteria, with word-sequence meaning and
casing/context checks remaining bounded proxies. Equivalent plans can still cause false failures.
Benign Unicode raw fallback is accepted as preservation, not sanitization. Shared correction/context
templates mean the suite measures new utterances within familiar patterns, not distributional independence.
Four focused policy/probe/release/leakage checks passed during review. No model was queried by the reviewer.

The prior allowlist and native-probe blockers are closed. Standards: zero unresolved findings.
Spec: zero unresolved findings in this frozen scope. Production speech coverage, physical M1 gates,
security review, and model-quality acceptance remain separate requirements.

The retained [native probe evidence](../../evidence/release-v2-native-probes.json) records all 16
results, exact runner/source identity, and fixture hash. It proves controlled boundary behavior only.
