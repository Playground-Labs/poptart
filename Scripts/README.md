# Verification and release commands

- `dev-run.sh` builds Poptart into an ad-hoc-signed `.app` bundle pinned to `labs.playground.Poptart` and launches it, so permission grants survive rebuilds.
- `PoptartVerifier/main.swift` is a Foundation-only executable source intended to be the root package's `PoptartVerifier` target.
- `test_tooling.py` exercises deterministic corpus/evaluation behavior and fail-closed benchmark prerequisites.
- `benchmark_release.py` accepts only a real executable runner, exact local model, macOS 15+, and the physical 8 GB Apple M1 baseline.
- `release/verify_release_inputs.py` validates real artifact hashes and measured reports before release.
- `release/sign_model_pack.sh` emits the base64 JSON envelope decoded by `SignedModelPackManifest` and refuses example or incomplete manifests.
- `release/notarize_app.sh` verifies Developer ID signing, submits with an existing Keychain profile, staples, and validates.

No script contains credentials, downloads a model implicitly, or turns absent evidence into success.

## Benchmark runner

```sh
swift build -c release --product PoptartBenchmark
RUNNER="$(swift build -c release --show-bin-path)/PoptartBenchmark"
"$RUNNER" --fixtures Evals/fixtures/gold.jsonl --model /path/to/pack \
  --audio /path/to/audio --jsonl
python3 Scripts/benchmark_release.py --runner "$RUNNER" --model /path/to/pack \
  --audio /path/to/audio --output .build/m1-report.json
```

The unpacked pack needs `manifest.json` with a positive, measured `cleanupTokenCeiling`,
`recognition/unified/` with the pinned FluidAudio assets, and `cleanup/` with Qwen weights,
configuration, and tokenizer files. Optional `recognition/ctc/` enables vocabulary boosting.
The runner does not download anything, invent a ceiling, or validate a pack's release signature.
Use the exact verified release pack when collecting release evidence.

Provide one `<fixture-id>.wav` per JSONL fixture: nonempty mono audio, finite samples, shorter
than five minutes. Audio is decoded only by this development executable. Use synthetic/public
fixtures; JSONL output includes delivered text. IDs must contain only ASCII letters, digits,
hyphens, and underscores. All audio inputs are checked before any result is emitted.

The runner warms both models once, replays audio at device pace, and measures the existing
coordinator's release-to-delivery timing with its production deadlines. Delivery is a controlled
in-memory destination: these timings **exclude live Accessibility and clipboard insertion**.
They are pipeline evidence, not a replacement for the compatibility harness or manual delivery
checks. Model failures and fallback outcomes remain visible; incomplete timings fail the run.

`footprintBytes` is the post-Dictation physical footprint; the report's steady-state value is the
maximum of those snapshots. `peakFootprintBytes` is the kernel's process-lifetime physical
footprint high-water mark, including model loading and fixture decoding. `mlxActiveBytes` is
MLX's active allocation count, not a substitute for physical footprint. No memory threshold is
invented. Both models must remain loaded at every sample.

The runner writes and decrypts history through the production stores with a per-run in-memory
key, and round-trips settings. Its default temporary directory is deleted on exit. An explicit
`--history-directory` must be empty; records remain encrypted there after exit, but the
throwaway key is not retained. Never point this option at a person's Poptart data.

For the release baseline, reboot a physical **8 GB Apple M1**, run macOS 15 or newer, close other
applications, and run the optimized command above without a prior inference run. Models load
before timed Dictations. Preserve the report, exact pack, fixtures, OS version, and operator notes.
The bundled gold corpus is a tooling smoke set; a representative release corpus and real model
artifacts are still required before claiming product-level p99. The Python gate rejects other
hardware, incomplete fixture coverage, invalid numbers, and absent residency/readback evidence.
Release input verification recomputes the summary from rows and matches latency, token ceiling,
and both memory measurements to production metadata; those fields stay null until measured.
Pass the same `--fixtures PATH` to the benchmark and release verifier when using a larger corpus.

## Privacy evidence

```sh
# Works without a pack; expected exit 3, dictationProven=false.
zsh Scripts/privacy/network_deny.sh --startup-only
# Requires real audio and the complete local pack; expected exit 0 only after successful Cleanup.
zsh Scripts/privacy/network_deny.sh --model /path/to/pack --audio /path/to/audio
# Optional --fixtures PATH selects the corpus matching those audio files.
# Interactive clean-install capture; authorize native packet capture first.
sudo -v
zsh Scripts/privacy/traffic_capture.sh
```

The deny script verifies IPv4/IPv6 connection attempts fail with kernel `EPERM`, launches the
ad-hoc DEBUG app in isolated storage, then runs the benchmark under the same sandbox. A full
pass requires every fixture to produce cleaned text plus encrypted-history and settings readback.
Fallback-only runs cannot pass. Logs and JSONL remain in `.build`; temporary app data is removed.
Local system IPC remains permitted. The sandbox constrains the launched processes, not unrelated
system services; it is not a shipping app entitlement or a claim about every possible code path.

The traffic script needs an interactive terminal, administrator capture privileges, a hosted
signed manifest, and `POPTART_MODEL_PACK_PUBLIC_KEY` configured for `dev-run.sh`. It starts native
`tcpdump` PKTAP capture on all interfaces before app launch, filters Poptart/effective-process
metadata, then checks the exact launched PID offline. Mark the download window **before requesting
the manifest**, and close it after installation and its network transfers finish. The script
observes another 20 seconds and retains the PCAPNG, packet listing, capture statistics, installation
receipt, and phase timestamps beside the output report. Capture errors, process-attribution
mismatches, packet loss, missing phases, and absent downloads fail instead of counting as silence.
Browser actions (source code/update links) are outside this process capture; do not exercise them.
The result covers this ad-hoc build and this observed session, not notarized-release certification.

Both scripts rebuild the development bundle and quit a running development Poptart first. Neither
modifies the normal support directory. An interrupted/failed run leaves `passed: false` rather than
a stale passing report. Full model execution, hosted download capture, and physical-M1 measurements
remain pending until their external prerequisites exist.
