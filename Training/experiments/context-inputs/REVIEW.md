# Vocabulary context corrections — September 17, 2026

This snapshot corrects eight training-positive records from the frozen position-inputs
corpus. Seven raw utterances now explicitly identify application/software use; the eighth
already identified a workspace. Each positive uses the same two-entry vocabulary list as
its physical-object negative, with target order balanced four/four. Articles no longer
separate name positives from object negatives. `corrections.json` retains exact before/after
records. Other 760 source lines remain byte-identical, including validation/test and all
eight physical-object negatives. Splits remain 704 train / 32 validation / 32 test.

Independent reviewers `comparison_spec` and `comparison_standards` checked the entire draft
against position-inputs. Both cleared the corrected meaning, spans, clean text, pair balance,
unchanged records, corpus builder, and duplicate/partition checks against evaluation fixtures.
This addresses identified supervision ambiguity, not proof that it caused the model errors.
No runtime, prompt, validator, historical experiment, or held-out label changes are involved.

The physical diagnostic contains existing training records, and the spelling/position
matrices informed prior data design. None is independent release evidence. The frozen
release holdout remains unqueried. Training uses the archived chat splits directly.
