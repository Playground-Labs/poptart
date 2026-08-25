# Run Cleanup only on finalized transcripts

Cleanup will begin only after speech recognition produces the finalized Raw Transcript. Poptart may load and prepare the Cleanup Managed Model during Recording, but it will not edit partial recognition speculatively; this preserves whole-utterance correction semantics and keeps unstable intermediate text outside the Cleanup contract.
