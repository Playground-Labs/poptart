# Managed Model release metadata

`production-config.json` is the single machine-readable declaration of the exact runtimes and model choices implemented by Poptart. Its `unreleased` state is deliberate: artifact sizes, hashes, the Cleanup token ceiling, quality evidence, and physical-M1 latency must come from real release artifacts and measurements.

`model-pack.example.json` demonstrates the manifest shape but is intentionally invalid for installation. Release tooling refuses null evidence and the `exampleOnly` marker. No model weights are stored in Git.

The Qwen base revision is pinned to `2fc06364715b967f1860aea9cf38778875588b17` and is Apache-2.0 licensed. FluidAudio and Parakeet artifacts must retain their upstream notices when packaged.
