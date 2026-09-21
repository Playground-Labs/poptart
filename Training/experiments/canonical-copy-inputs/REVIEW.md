# Canonical spelling contrasts — September 17, 2026

Adds 128 authored train-only records: eight existing spoken object terms × four supplied spelling
styles × two frames × explicit application/physical contexts. Original 960 corpus lines and all
896 generated training chats remain byte-identical prefixes; validation/test bytes are unchanged.
Result: 1024 training / 32 validation / 32 test. The original preservation examples are retained.

Reviewers comparison_spec and comparison_standards independently checked every new training label
and all 64 prospective diagnostic labels. Their findings were fixed before training: the partition
exception now permits only case/spacing variants of the same vocabulary identities in training;
evaluation-list membership remains authoritative regardless of split tags. Repeats and reordered
vocabulary sets still reject. Initial casing, terminal punctuation and vocabulary slot cover all
eight combinations within each training style/frame/domain group. Diagnostic distractors rotate
among positively used novel identities. Both reviews cleared the revised data.

The new diagnostic has four unseen terms in four spelling styles, two span positions, and two
semantic domains. Its 64 cases are repeated contrasts, not 64 independent terms. It is excluded
from training and checkpoint selection. Older diagnostics informed previous data revisions and
are not independent release evidence. No frozen release predictions are generated.

The author script expects the preserved 960-row preservation corpus hash. To reproduce, start
from preservation-inputs/corpus.jsonl; do not run against the expanded production corpus.
The unchanged training recipe starts from the composition adapter; the added data is the
intervention. Native evaluation uses the repaired optimized runtime whose outputs were checked
against debug on both retained models. No automatic model promotion is permitted.
