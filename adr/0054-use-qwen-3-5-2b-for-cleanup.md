# Use Qwen 3.5 2B for Cleanup

Poptart will ship one task-specific, four-bit Qwen 3.5 2B Cleanup Managed Model for the MVP.
This supersedes ADR 0039's 0.8B choice. The larger model is selected because the completed native
experiments show materially better generalization across development mechanics, personal vocabulary,
and physical-versus-application context. The selected development candidate is the separate
higher-precision adapter in `Models/Artifacts/diverse-contexts-step128` on the unchanged four-bit
affine base.

The observed regression aggregate is 555/564 exact plans, 558/564 meaning preservation, and 561/564
context fit, with every adversarial and runtime check passing. Five focused physical-object cases still
received unwanted vocabulary substitutions, and two development cases missed cleanup or fell back.
These residuals are accepted for the usable MVP and remain explicit post-MVP quality work; they are not
represented as perfect accuracy.

The candidate's one permitted frozen `release-v2` evaluation preserved meaning in 48/48 gold cases,
Personal Vocabulary in 4/4 applicable cases, adversarial safety in 22/22 cases, and runtime consistency
in 70/70 cases. It produced the expected delivered text in 38/48 cases. Most misses were punctuation;
three long inputs safely fell back to the Raw Transcript. It did not pass the stricter release gate:
32/48 exact edit plans and 44/48 context-fit cases. The retained result is
`Training/experiments/practical-candidate-release-v2-2026-09-18.json`.

This is the usable MVP candidate, not a qualified release artifact. No holdout-driven retraining or
threshold change follows this result. Measured baseline latency and memory, signed Model Pack privacy
capture, and distribution smoke remain release work. ADR 0055 makes the M5 Pro the beta baseline and
keeps 8 GB M1 performance unverified. The missed question punctuation, long-input
fallbacks, and sentence-boundary mechanics are post-MVP quality work.
