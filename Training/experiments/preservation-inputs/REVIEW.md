# Preservation coverage — September 17, 2026

Adds 192 authored train-only records to the corrected context corpus: 128 ordinary physical
object references despite supplied matching vocabulary, 32 empty-vocabulary software references,
and 32 software references with unrelated vocabulary. All original 768 corpus lines and validation/
test splits remain byte-identical. The resulting split is 896 train / 32 validation / 32 test.

Independent reviewers comparison_spec and comparison_standards checked every added label and
all 32 novel diagnostic records, builder/partition integrity, and preservation of existing data.
Review corrected a fixed-distractor shortcut by rotating positively used existing names. It also
uncoupled physical-example capitalization from vocabulary order. The novel probe crosses each
spelling style with both application span positions and both target vocabulary slots; all eight
unseen terms have two physical and two explicit application contexts. Both reviewers cleared the
revised data. Generator assertions retain these checks.

The new probe is prospective and excluded from training and checkpoint selection. The original
physical diagnostic is training data; earlier position/spelling probes informed data design.
None substitutes for the frozen release holdout or representative human speech. No prompt, runtime,
validator, held-out label, or previous experiment snapshot changes are involved. Training uses the
archived chat splits, not mutable production files. Author scripts retain the expected pre-change
corpus hash and should be reproduced from the context-inputs baseline, not the expanded corpus.
