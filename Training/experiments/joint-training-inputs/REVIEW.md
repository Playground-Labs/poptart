# Joint training inputs

This development-only snapshot combines four previously reviewed training-only chat sets: 1,024 retained original examples, 512 diverse-object additions, 1,024 focused-context contrasts, and 128 mechanics examples. It contains each serialized chat exactly once and retains byte-identical validation and test splits. No evaluation or diagnostic row is added.

Independent Spec review verified the exact source slices and order, unique prompts, valid targets,
CC0 provenance, unchanged splits, and only the eight already-documented training-fit diagnostic
repeats. Independent Standards review revalidated all 2,688 labels, prompt-disjoint splits, and the
deterministic 21-row blocks. Both reviews are clear. This data supports a bounded simultaneous-training
experiment; it does not establish accuracy or isolate model capacity from initialization effects.
