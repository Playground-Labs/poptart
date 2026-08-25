# Use FluidAudio as the recognition adapter

Poptart will use FluidAudio's native Swift/Core ML pipeline with the English Parakeet TDT v2 model for MVP speech recognition. FluidAudio remains a replaceable adapter behind a Poptart-owned recognition interface; Poptart owns audio capture, incremental processing policy, Managed Model distribution, lifecycle, Personal Vocabulary integration, and latency behavior.

The FluidAudio adapter decision remains active. ADR 0051 supersedes the TDT v2 artifact choice after implementation research showed that its current sliding-window API cannot provide short-Dictation incremental hypotheses.
