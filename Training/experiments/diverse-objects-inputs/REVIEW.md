# Diverse-object contrast draft review

The experiment adds 512 training examples across 32 new terms, four supplied spellings,
two sentence frames, and application/physical domains. The original 1,088 corpus records
and 1,024 training chats remain exact prefixes; validation and test bytes are unchanged.
Research inputs are isolated here; the main corpus has not been replaced.

The prospective diagnostic has 128 cases across eight other terms, four spellings,
two frames, and both domains. It is excluded from training and checkpoint selection.
These are synthetic cases covering eight terms, not 128 independent concepts.

Both independent reviewers examined all 640 new labels. Review found and removed two
style shortcuts: fixed CamelCase distractors, then application templates correlated with
distractor style. Final assertions verify every target-style/application-template group
contains all four distractor styles twice and all eight mechanics/order combinations once.
Both reviewers cleared the final draft. Physical references stay physical; application
corrections copy the supplied spelling exactly.

Python target application and partition checks passed. The existing partition guard reads
release records only to detect leakage; no release labels were emitted or used for design.
Eight older physical training-fit diagnostic duplicates are excluded only after asserting
the original training input and labels match. Other prior diagnostics remain held out.

A temporary native contract test checked all 1,600 corpus records plus the 128 prospective
labels, including exact Swift/Python prompt and target agreement for generated chats.
The temporary test was removed after passing; source is retained in
.context/DiverseCorpusContractTests.swift. Log: .build/diverse-objects-native-labels.log.
Training preflight checked 1,536/32/32 records with maximum sequence length 427.
No new model inference had occurred when this review was recorded.
