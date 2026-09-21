# Security review — September 16, 2026

Status: source review and focused regression checks completed; release evidence remains incomplete.
The independent Standards and Spec reviewers examined encrypted storage, logging, Model Pack trust,
application updates, signing, and privacy tooling against SPEC and the ADRs. This is an agent code
review, not a claim of certification or measured production behavior.

## Findings addressed

| Finding | Change and check |
| --- | --- |
| FluidAudio logs transcript/vocabulary contents | Disable its logger before constructing recognition components. Debug/release console probes exercise the actual SDK logger. Both reviews cleared the ordering. **Published and pinned at `61dc8edf`; both fresh checkouts and all local suites pass.** |
| Mechanical Cleanup edits could remove embedded symbols | Preserve symbol graphemes across every model edit. Three native regressions reproduce filler, repetition, and vocabulary deletion; the Python mirror agrees. |
| Punctuation/casing edits could change numeric or URL literals | Compare recognized literals before and after model edits, using the deterministic correction result as the reference. Shared Swift/Python cases cover decimals, signs, percentages, URL paths/queries, and domain names, plus allowed punctuation and authoritative corrections. Both suites reproduced 14 unsafe acceptances before the fix and pass all 18 cases afterward. This is a mechanical preservation guard, not comprehensive semantic validation. |
| Malformed versions could crash or escape staging | Validate the entire numeric dotted release version, rejecting empty strings and suffix/path content before download. Normalize equivalent trailing-zero versions. |
| Actor reentrancy allowed overlapping installations | Reject a second transaction while an installation is suspended. A blocked smoke-test regression proves an older installation cannot overtake it. |
| Download limits applied after writing the full response | Check declared length, bound streaming bytes and disk writes, cancel the underlying request, and retain bounded partial data. Native transport tests cover oversized bodies, resumed ranges, and servers ignoring Range. |
| Startup trusted mutable manifest/hash metadata | Retain the signed envelope and authenticate it again on startup. Require current metadata to match. Repair can recover damaged mutable metadata while preserving the authenticated version floor; a missing/invalid envelope fails closed with a specific recovery error. |
| Expiry depended on opening History | Run retention every minute while the app lives and before writes. Continue scanning after individual corrupt records. Injected-clock tests inspect disk without reading History. |
| Development storage shared the production Keychain namespace | DEBUG overrides use a stable per-directory development namespace; release always uses the production identity. |
| Encryption tampering lacked explicit regression coverage | Ciphertext and authenticated-metadata modifications both fail to decrypt. |
| Release archives did not match runtime model paths | Signed manifests now enumerate individual runtime files, including optional root VAD. Native installation and startup tamper checks exercise the layout. |
| Performance evidence could describe different shipping files | Bind benchmark results to both model inventories (including VAD), manifest, runner, source/dependency pins, fixtures and audio. Mutation and missing-identity regressions fail closed. |

AES-GCM encrypts transcript, delivered text, destination identity, and Personal Vocabulary.
Metadata is authenticated; Target Context and audio are not persisted. Secure-target rejection
produces no history. Application updates require an explicit action and signed feeds/archives;
release assembly validates Developer ID, Team ID, hardened runtime, timestamp, and entitlements.

A [real Keychain probe](../Evals/evidence/keychain-persistence-2026-09-16.json) compiled the
production Persistence source into a local development executable. Separate processes wrote and
read synthetic history/vocabulary, deleted only a UUID-scoped test key, verified both stores
became unreadable, reset both stores, and successfully wrote/read again. Sensitive canaries were
absent from stored plaintext. The final check verified removal of the test key; temporary storage
was removed. Source, executable hashes, build command and all seven phase results are retained.
This establishes local provider behavior, not the signed application's Keychain identity or
behavior across installation and updates.

The [literal-preservation evidence](../Evals/evidence/literal-preservation-2026-09-17.json)
retains the failing/passing regressions, 14 rebuilt native fallback probes, full repository
verification and optimized app build logs. Rechecking the retained composition model and latest
low-rate candidate preserved all 46 raw plans, outcomes and outputs. Development exact scores
remain 11/12 and 10/12 respectively; the fix does not establish model quality or release readiness.

The native control-class compatibility run passed all 13 controls and calibration. Its first run
exposed a stale harness assertion: ADR 0052's successful `noTarget` result was mistaken for an
editable target. The harness now requires that exact result for unsupported controls.

## Evidence still required

A combined integration review found that checking only listed file hashes allowed unlisted
weights or layout directories to influence model loading. Installation now checks staged paths
before reuse, then requires the exact signed file inventory before smoke testing; startup applies
the same inventory check before hashes. Symlinks, nonregular files, and unsigned directories are
rejected. Corrupt staging is discarded so Repair can retry. Eight tampering cases and the complete
22-test ModelRuntime suite pass, including paths under macOS's `/var` alias.

The same review fixed retries of fully written partial artifacts: they are verified and promoted
without an invalid Range request at EOF; corrupt partials fail and are discarded. Release quality
verification now requires prediction token counts to match the shipping Cleanup ceiling, including
the predecessor's own ceiling when comparing releases. All 37 Python tooling tests pass.

Release-only checks now also enforce four-bit Qwen base configuration/weight packing and complete
CTC vocabulary assets. Settings Update and Repair await runtime activation before reporting success.
Replacing a runtime releases and finishes its current Dictation, keeps deadlines active through
completion, joins warmup/history work, and refuses further presses before unloading. Delayed old
presentation callbacks cannot overwrite the new runtime. Focused tests cover capture, recording,
Cleanup, delivery, history, activation failure, and restart during initial loading. The combined
root/all-six-package verification, 38 Python tests, and 2,861 repository checks pass. These checks
do not establish signed installation/update behavior or release model quality.
The [integration review evidence](../Evals/evidence/integration-review-2026-09-17.json) retains
source hashes, reviewer conclusions, test logs, and the optimized application build log.

The [published FluidAudio fork](https://github.com/brandon-nextwork/FluidAudio/commit/61dc8edf915e528a11d81ded84b83d2709746713)
resolved into clean root and standalone Recognition checkouts. `Scripts/verify.sh` passed root/all six
package suites (106 root tests), 34 Python tests, 1,648 verifier checks, and both logger probes
(`.build/pause-full-verification.log`). The optimized app build passed. Startup-only network denial
correctly returned exit 3 and `passed: false`; it establishes settings access and IP denial only.

Still required:
- Complete a real hosted-download capture. The automated checker proves timing and process
  attribution; `destinationsVerified: false` explicitly leaves destination/request reconciliation
  open. Retain and examine PCAPNG, signed installation metadata, and redirect destinations.
- Repeat offline Dictation with a qualifying model. The current synthetic 12-fixture run completed
  encrypted readback under IP denial, but the latest coverage candidate produced four raw fallbacks, correctly preventing a full pass.
- Exercise the signed release's actual Keychain behavior, signing/notarization, update rejection,
  installation, and relaunch. In-memory tests and the isolated development Keychain probe do not
  establish those signed-distribution facts.

Retention can lag by one minute while running, or until launch after the app is closed. Malformed
records remain available for explicit recovery while other expired records are removed. Logging
suppression is a startup policy, not a way to retract messages already queued. Local filesystem
administrators and replacement of the app itself are outside the publisher-signature trust boundary.

Focused checks: `ModelPackInstallerTests`, `DownloaderTests`, `HistoryStoreTests`,
`CleanupBoundaryTests`, `RuntimeWiringTests`, `SettingsSurfaceTests`, `Scripts/test_tooling.py`,
and `Scripts/privacy/check_fluid_logging.sh`. The declared physical Apple Silicon benchmark and full live smoke gates remain
separate release requirements.
