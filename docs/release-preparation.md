# Release preparation

The repository remains unreleased. `Models/production-config.json` intentionally
has null artifact sizes, hashes, and measured release fields. Do not replace
those values with development-run results.

## Checks available without release credentials

Run from the repository root:

```sh
python3 Scripts/test_release_tooling.py
sh -n Scripts/release/sign_model_pack.sh
sh -n Scripts/release/notarize_app.sh
```

The six offline tests use temporary synthetic artifacts and reports. They cover
consistent evidence, unreleased/changed evidence rejection, malformed numeric
measurements, contradictory M1 pass claims, boolean artifact sizes, and duplicate
roles or boolean sizes reaching the signing command. A valid two-artifact manifest
reaches the OpenSSL stub as a positive control. The signing test substitutes
a stub for OpenSSL; it neither creates a key nor signs an artifact.

The release-input verifier now requires an actual boolean M1 pass flag, a finite
nonnegative p99 no greater than 1500 ms matching the configured measurement,
positive integer sample counts, and at least 99 percent of samples within the
1500 ms deadline. These fields match `Scripts/benchmark_release.py` output.
It also rejects boolean token ceilings and artifact sizes, which Python otherwise
treats as integers. Manifest signing requires exactly two distinct artifact roles.

Verification on 2026-10-20: all six tests passed, and both shell scripts passed
`sh -n`. Before the fixes, the regression suite produced 20 failing assertions
across malformed measurement and signing cases. No production metadata changed.

## Evidence and access still required

1. Select a Cleanup artifact that passes the agreed quality gates. Preserve its
   exact source revision, tokenizer/template, quantization, and quality report.
   Existing development evaluations do not establish release qualification.
2. Run the production benchmark on a physical 8 GB Apple M1, macOS 15 or newer,
   with the selected model. Measure the Cleanup input token ceiling. Separately
   measure the full-app key-up-to-delivery deadline; `Scripts/benchmark_release.py`
   consumes Cleanup-only timings and cannot establish that end-to-end gate.
   A cloud GPU or an M3 run cannot substitute.
3. Build the exact recognition and Cleanup archives, retain licenses, and record
   each archive's real SHA-256 and byte size. Populate release configuration and
   the installable manifest only from those artifacts and accepted measurements.
4. Verify the release inputs before signing:

   ```sh
   python3 Scripts/release/verify_release_inputs.py \
     --config PATH_TO_RELEASE_CONFIG \
     --artifacts PATH_TO_ARCHIVE_ROOT \
     --quality-report PATH_TO_ACCEPTED_QUALITY_REPORT \
     --m1-report PATH_TO_PHYSICAL_M1_REPORT
   ```

5. Use the controlled Ed25519 release key to sign the manifest, publish the exact
   archives and signed envelope at their production URLs, and exercise download,
   installation, integrity failure, rollback, and offline inference with the
   release app. Release-key access and hosting are external prerequisites.
6. Complete the functional/privacy checks, sign the app with the release identity,
   and use the configured Apple notary credentials with
   `Scripts/release/notarize_app.sh`. Validate the stapled application and its
   installation on a clean supported Mac before distribution.

## Limits of the current scripts

`verify_release_inputs.py` checks the quality report's hash, not its quality
judgment. The current M1 report does not contain an artifact hash or token ceiling,
so this script cannot prove it describes the exact published model or measured
ceiling. Preserve and review that association in the release evidence; a passing
script alone is not launch approval. The signer performs limited preflight checks,
not complete manifest-schema or artifact verification. No signing, notarization,
network installation test, production publication, or physical M1 run was performed
by these offline checks.
