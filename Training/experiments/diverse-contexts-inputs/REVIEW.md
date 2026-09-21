# Focused diverse-context review

This focused continuation contains 1,024 new training examples across 32 terms,
four supplied spellings, four sentence frames, and physical/application domains.
It intentionally trains only on these new records while retaining the prior selected
adapter. Validation and test chats remain byte-identical to the preceding experiment.

The prospective diagnostic contains 256 cases across eight other terms, four spellings,
four frames, and both domains. It was authored and reviewed before model inference and is
excluded from training and checkpoint selection. These are synthetic cases over eight
concepts, not 256 independent concepts.

Independent review found two pre-inference issues. `wooden chest` overlapped an older
diagnostic term and was replaced with `wicker hamper`; novelty checks now include every
prior diagnostic vocabulary entry. The first prospective mechanics schedule also leaked
distractor style and then target slot through sentence frame. The final schedule gives
every diagnostic template both target slots for every target and distractor style, and
joint assertions enforce that coverage. Both reviewers cleared the regenerated data.

All 1,280 labels passed Python semantic, span, partition, and prompt construction checks.
A temporary native contract test verified the Swift prompt, parser, validator, and applier
against every training and prospective row; its source is retained at
`.context/DiverseContextContractTests.swift` and its passing log at
`.build/diverse-contexts-native-labels.log`. The pinned tokenizer preflight validated
1,024/32/32 chats with a maximum sequence length of 407 tokens.
