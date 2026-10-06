# Verification and release commands

- `PoptartVerifier/main.swift` is a Foundation-only executable source intended to be the root package's `PoptartVerifier` target.
- `test_tooling.py` exercises deterministic corpus/evaluation behavior and fail-closed benchmark prerequisites.
- `benchmark_release.py` accepts only a real executable runner, exact local model, macOS 15+, and the physical 8 GB Apple M1 baseline.
- `release/verify_release_inputs.py` validates real artifact hashes and measured reports before release.
- `release/sign_model_pack.sh` emits the base64 JSON envelope decoded by `SignedModelPackManifest` and refuses example or incomplete manifests.
- `release/notarize_app.sh` verifies Developer ID signing, submits with an existing Keychain profile, staples, and validates.

No script contains credentials, downloads a model implicitly, or turns absent evidence into success.

Recognition's opt-in production-adapter audio replay and the remaining ADR 0051
qualification requirements are documented in [recognition-benchmark.md](../docs/recognition-benchmark.md).
The replay is exploratory; it does not certify the full application's M1 deadline.
