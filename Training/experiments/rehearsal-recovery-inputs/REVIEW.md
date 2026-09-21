# Rehearsal recovery inputs

The train split interleaves all 1,024 retained pre-context examples with all 1,024 focused context examples, preserving each source record byte-for-byte and giving both sources equal weight. Validation and test are unchanged copies of the frozen 32-record splits. No evaluation fixture is added to training.
