# Functional and privacy verification evidence

Issue: [#6](https://github.com/Playground-Labs/poptart/issues/6).
This is development evidence, not signed-release qualification. Unchecked items
below remain launch gates; unit tests and source scans do not prove network silence.

## Recorded development pass

- Date: 2026-10-20 America/Chicago (2026-10-21 UTC).
- Base revision: `63dbca51f65d4709c43c2a10c95b887eb3a6a8c0`, plus the
  Persistence regression tests accompanying this document.
- Host: macOS 27.0.1 (26A434), arm64; Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`). Package tests use debug builds.
- No permissions were changed, real installation keys deleted, or network access
  blocked during this pass. Fixtures contain synthetic data in temporary directories.

| Command | Observed result | Evidence scope |
| --- | --- | --- |
| `swift test` | Exit 0; 87 tests in 9 suites passed | App integration, settings, onboarding, and model-pack surfaces |
| `swift test --package-path Packages/Persistence` | Exit 0; 7 tests in 1 suite passed | Encrypted history/vocabulary, expiry, deletion, simulated key loss, safe reset, and tamper rejection |
| `swift test --package-path Packages/SystemIntegration` | Exit 0; 89 tests in 11 suites passed | Target classification, secure-input capture, clipboard ownership/restoration, cancellation/deadlines, focus/selection evidence, shortcut and indicator policies |
| `swift Scripts/PoptartVerifier/main.swift` | Exit 0; 1,155 checks passed | Configuration, dependency pins, synthetic provenance, model-pack templates, and forbidden-API source scan |

Local logs are `.context/privacy-persistence-tests.log`,
`.context/privacy-system-tests.log`, and `.context/privacy-repository-verifier.log`.
The `.context` directory is gitignored; the commands and observed summaries above
are the durable record. The root integration log is `.context/parallel-root-tests.log`. Parent verification
independently repeated both package suites and the repository verifier successfully.

## What the tests establish

`HistoryStoreTests.swift` checks that raw transcript, delivered text, destination
application, and vocabulary terms do not appear as plaintext in fixture files.
The history payload uses AES-GCM with metadata authenticated as additional data.
The new tests mutate valid metadata or ciphertext and require an unreadable-data
error, rather than returning an altered record. They also exercise vocabulary
key loss, removal of unreadable data, and saving replacement vocabulary.

Key-loss tests use an in-memory key provider. They establish decryption failure
under a replacement key, not actual Keychain deletion, backup erasure, memory
zeroization, or forensic unrecoverability. History metadata (including timestamps,
record IDs, outcome, and timings) remains readable by design; the test does not
claim that the entire file is encrypted. Expiry is enforced when records are read
or `expireRecords()` is called, not by a separately tested background timer.

SystemIntegration tests cover native and web password metadata, capture while
secure input is active, target identity/selection revalidation, and clipboard
restoration after success and owned timeout. Foreign clipboard ownership is
preserved; cancelled or expired deliveries do not replace clipboard contents.
These are controlled adapter/policy tests. Real password fields, actual Cmd-V
consumption, and window-server focus still require the compatibility harness and
manual smoke checks.

The repository privacy scan rejects selected networking/telemetry/audio-file APIs
outside allowed source boundaries. It is a static scan of first-party sources,
not an audit of every dependency, traffic capture, or a runtime log-redaction test.

## Remaining release evidence

- [ ] Run `Tools/Compat/run.sh` and retain its matrix for the candidate build. It
  opens a host app and requires Accessibility permission for the driver. Record
  refusals separately from failed supported-control cases.
- [ ] Complete every result in [manual-smoke.md](manual-smoke.md), including
  first-run/restart permissions, real speech, native/browser/Electron/terminal
  controls, secure-field refusal, indicator focus/privacy, and five-minute stop.
- [ ] With model artifacts already installed, deny outbound access for the app
  and exercise Dictation/inference, settings, and history. Record the denial
  mechanism, build identity, logs, and observed outcomes. Keep this separate from
  clean-install download testing; inference must not depend on a hidden fetch.
- [ ] On a clean disposable macOS account, capture attributable app traffic from
  startup through idle, settings/history use, Dictation, and explicit model
  download. Record destinations/timestamps and the initiating action. A successful
  offline run alone does not establish that no requests were attempted.
- [ ] Use synthetic unique text, vocabulary, and clipboard markers in the app;
  inspect its persisted files and captured process logs for those markers. Do not
  use personal dictation as a test fixture. Check audio/level/context logging too.
- [ ] In that disposable account, record the exact test installation's Keychain
  service/account before deleting only its key. Confirm old history and vocabulary
  cannot be read, exercise the app's available reset/clear paths, and verify new
  records and vocabulary work. Never delete a user's existing installation key
  as a release test. Confirm the vocabulary recovery UI, not merely the store API.
- [ ] Retain model-runtime evidence for bad signature/checksum, unsupported or
  downgraded manifests, interrupted download, and atomic activation/rollback.
- [ ] Repeat the relevant end-to-end checks against the final signed build and
  record its version, artifact hash, OS, and results before closing issue #6.

This pass does not satisfy the physical 8 GB M1 performance gate or Cleanup model
quality qualification. Those require their own evidence.
