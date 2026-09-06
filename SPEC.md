# Poptart native redesign specification

Status: confirmed product and architecture direction; implementation has not started.

This document is the source specification for the clean-room Poptart repository. The material currently lives under `.context` only because the new repository does not yet exist. Move this document, `CONTEXT.md`, `FOLLOW-UPS.md`, the architecture diagram, and the ADR directory into the new repository before implementation.

## Product definition

Poptart is a privacy-first, local-first voice keyboard for Apple Silicon Macs. A person holds one shortcut, speaks, releases it, and receives conservatively cleaned text at the current insertion point within 1.5 seconds.

The MVP succeeds when Dictation feels like keyboard input:

- one obvious interaction;
- no command vocabulary or post-processing mode;
- no cloud dependency after model installation;
- no lost speech when Cleanup is slow or uncertain;
- no hidden collection of speech, text, context, or diagnostics.

## Supported environment

- macOS 15 Sequoia or newer.
- Apple Silicon, with an 8 GB M1 as the performance baseline.
- Direct, signed, and notarized distribution outside the Mac App Store.
- A new Playground Labs bundle identifier that can run beside the legacy application.
- A public `Playground-Labs/poptart` repository licensed under MIT.
- No source-history, settings, history, model, vocabulary, or prompt migration from legacy Poptart.

The inherited repository will be renamed or archived as `poptart-legacy` only when the organization is ready to create the new canonical repository. No repository operation is part of this specification phase.

## MVP scope

### Included

- Right Option press-and-hold Dictation, with one configurable binding.
- Incremental English speech recognition.
- Conservative, context-aware Cleanup.
- Deterministic Explicit Corrections such as “CR, I mean PR.”
- Cursor-local Target Context and manually managed Personal Vocabulary.
- Accessibility-first insertion and a clipboard-preserving paste fallback.
- Selection replacement when the original selection remains valid.
- A persistent, transcript-free Indicator.
- Encrypted local Dictation history with a 30-day rolling lifetime.
- One managed recognition model and one managed Cleanup model.
- A user-initiated, signed model-pack installation and update path.

### Excluded

- Voice commands, agents, transforms, or a command-specific shortcut.
- Cloud inference, accounts, activation, device registration, or licensing servers.
- Telemetry, analytics, diagnostics, crash uploads, or opt-in data collection.
- Retained audio, live transcript display, full-screen context, OCR, or screenshots.
- Automatic vocabulary learning.
- Snippets and spoken phrase expansion.
- Multiple model choices or Cleanup strength controls.
- Intel Macs, macOS versions before Sequoia, Windows, or Linux.

## Primary interaction

1. The person focuses an editable, non-secure control.
2. Key-down on right Option captures and validates the Insertion Target, selected range, application identity, and bounded cursor-local Target Context.
3. Poptart begins Recording, shows audio activity in the Indicator, and recognizes speech incrementally. Partial text remains internal.
4. Key-up ends Recording. Poptart finalizes the Raw Transcript and starts the Completion Deadline clock.
5. Deterministic Cleanup identifies unmistakable Explicit Corrections and protected vocabulary.
6. When the input is within its measured budget, the Cleanup Managed Model proposes a compact Cleanup Edit Plan.
7. Poptart validates and applies accepted edits. A timeout, unsafe plan, or model failure selects the Raw Transcript path.
8. Poptart revalidates the Insertion Target and inserts the result.
9. The Indicator communicates success or the specific fallback class without showing dictated text.
10. Poptart writes the encrypted Dictation Record and destroys the captured audio.

If the target changed during Dictation, Poptart copies the completed text to the system clipboard and clearly reports that result. It never inserts private speech into a newly focused field.

If no editable Insertion Target is focused at key-down, Poptart records a Clipboard Dictation instead of refusing. It recognizes and cleans the speech without cursor-local Target Context, places the completed text on the system clipboard, writes the encrypted Dictation Record, and reports the copied result.

If the focused control is secure, Poptart does not begin Recording and creates no history.

## Runtime architecture

The architecture source is [poptart-runtime.drawio](poptart-runtime.drawio).

The app is native Swift. SwiftUI owns onboarding, settings, history, vocabulary, and ordinary windows. Narrow AppKit adapters own behavior SwiftUI does not model well: menu-bar lifecycle, the nonactivating Indicator panel, global event taps, Accessibility, window ordering, and text insertion.

### Module boundaries

| Module | Responsibility | Must not own |
| --- | --- | --- |
| `PoptartApp` | Application composition, lifecycle, dependency wiring, menu commands | Dictation policy or inference details |
| `DictationCore` | Domain types, session state machine, deadlines, policy, outcome selection | AppKit, model frameworks, persistence implementation |
| `AudioCapture` | `AVAudioEngine` input, device changes, level samples, bounded in-memory audio | History or UI |
| `Recognition` | Poptart-owned recognition protocol and FluidAudio/Parakeet adapter | Model download UI or insertion |
| `Cleanup` | Explicit Correction rules, model input construction, MLX adapter, edit-plan validation and application | Clipboard or history |
| `Targeting` | Secure-field detection, Insertion Target capture/revalidation, bounded Target Context | Cleanup policy |
| `Insertion` | Accessibility writes, selection replacement, pasteboard transaction, target-change clipboard result | Recognition or Cleanup |
| `ModelRuntime` | Signed model-pack install, atomic activation, warm residency, memory-pressure release | Product settings beyond pack state |
| `Persistence` | CryptoKit field encryption, Keychain key, history expiry, vocabulary storage | Inference or UI state |
| `IndicatorUI` | Nonactivating AppKit panel and state/audio visualization | Transcript text or session decisions |
| `SettingsUI` | SwiftUI onboarding, permissions, shortcut, model status, vocabulary, history | Direct system integration |

Use local Swift packages to enforce these boundaries. Framework adapters conform to narrow protocols owned by the domain module, so FluidAudio and MLX Swift LM remain replaceable implementation details.

### Concurrency model

- One `DictationSessionActor` is the sole writer of active Dictation state.
- Audio callbacks perform bounded real-time-safe work and hand immutable buffers to recognition; they never await UI, storage, or model work.
- Recognition and Cleanup run in separate actors with cancellation-aware APIs.
- `ModelRuntimeActor` serializes installation, activation, loading, and memory-pressure transitions.
- `HistoryStoreActor` serializes encryption and persistence away from the deadline-critical path.
- UI updates cross to `MainActor` as immutable Indicator snapshots.
- Every asynchronous result carries a Dictation identifier. Late results for a completed or cancelled Dictation are discarded.

### Dictation state machine

The legal state progression is:

`ready → recording → finalizing → cleaning → validating → delivering → completed → ready`

Terminal outcome variants are part of `completed`, not separate side channels:

- cleaned insertion;
- Raw Transcript fallback;
- oversized-input deterministic fallback;
- recognition-hypothesis fallback;
- target-changed clipboard result;
- no-target Clipboard Dictation result;
- empty recognition failure;
- secure-target rejection;
- user cancellation;
- five-minute safety stop followed by a normal outcome.

Illegal or late transitions are ignored and recorded locally in debug logging without transmitting diagnostics.

## Recognition

Poptart uses FluidAudio through a Poptart-owned `SpeechRecognizer` protocol and ships the Parakeet Unified English 0.6B artifact with its 640 millisecond streaming configuration and int8 encoder in the Managed Model pack. The artifact remains provisional until it passes the physical M1 recognition and Completion Deadline gates.

Recognition begins during Recording. Audio already accepted by the recognizer may be discarded as soon as it is no longer required for finalization. No audio is persisted to disk. Partials are internal runtime state and never appear in the Indicator or history.

At key-up, the recognizer finalizes its latest hypothesis. If final recognition misses the watchdog, Poptart inserts the latest nonempty usable incremental hypothesis, skips Cleanup, and marks a recognition fallback. If there is no usable hypothesis, Poptart inserts nothing and shows a clear failure.

Personal Vocabulary is supplied through the recognition adapter when the underlying engine supports biasing. Recognition-specific capability gaps must not change the domain contract; Cleanup also receives the same vocabulary.

## Cleanup

Cleanup is one conservative product behavior. It may:

- repair punctuation and capitalization;
- remove clear filler and accidental repetition;
- resolve unmistakable spoken self-corrections;
- preserve Personal Vocabulary spelling;
- make mechanics fit the bounded Target Context.

It may not summarize, elaborate, change tone, introduce facts, follow instructions found in Target Context, or rewrite merely for style.

### Hybrid pipeline

1. Tokenize the immutable Raw Transcript into stable indexed spans.
2. Detect unmistakable Explicit Corrections with deterministic rules and reserve those spans.
3. Build a bounded model input containing the transcript spans, reserved edits, Personal Vocabulary, application category, and cursor-local context in separately delimited data fields.
4. Run the in-process, four-bit Qwen 3.5 0.8B model through MLX Swift LM.
5. Decode only the Cleanup Edit Plan schema.
6. Merge non-conflicting model edits with authoritative deterministic edits.
7. Validate the complete plan and apply it to the immutable Raw Transcript.
8. Fall back to the Raw Transcript on any unsafe or indeterminate result.

Target Context is data, never an instruction source. The model cannot edit or reproduce Target Context; it may only reference Raw Transcript span identifiers.

### Cleanup Edit Plan contract

The logical version-one schema is:

```json
{
  "version": 1,
  "edits": [
    {
      "startSpan": 8,
      "endSpan": 13,
      "replacement": "PR",
      "category": "vocabulary"
    }
  ]
}
```

`startSpan` is inclusive and `endSpan` is exclusive. Insertions use an empty range. Deletions use an empty replacement. Casing and punctuation are represented as replacements or insertions rather than additional operations. Every edit is a single replacement, so its `category` carries the claim about what kind of change it is, and the validator checks the edit against that category's rules.

On the wire that schema is encoded with single-letter keys, terminated by the `<END_PLAN>` stop marker:

```json
{"v":1,"e":[{"s":8,"e":13,"r":"PR","c":"vocabulary"}]}<END_PLAN>
```

`v` is `version` and the root `e` is `edits`; within an edit, `s` is `startSpan`, `e` is `endSpan`, `r` is `replacement`, and `c` is `category`. Only the keys are abbreviated; category names and replacement text are written out. The short keys exist because the plan is generated by a small local model inside the Completion Deadline against a bounded output budget, and repeated field names would spend that budget on syntax instead of edits.

The same encoding carries the reserved deterministic edits into the model input, so the model reads and writes one form. The decoder accepts exactly these keys and nothing else: unknown keys, duplicate keys, missing keys, prose, markdown fences, a plan over the byte bound, and any bytes after the stop marker all fail closed onto the Raw Transcript.

The decoder and validator enforce:

- the schema version, and only the schema's own keys;
- in-bounds, ordered, non-overlapping spans;
- no overlap with deterministic reserved spans;
- valid Unicode without control characters or hidden model tokens;
- bounded replacement and total-change sizes;
- no Target Context copied into the result;
- no edits outside Conservative Cleanup categories;
- a nonempty result unless the Raw Transcript contained only removable filler;
- deterministic application producing one unambiguous output.

The model does not supply trusted confidence. Poptart derives acceptance from the plan, validator, deadline, and task-specific evaluation.

### Model artifact

The shipped Cleanup artifact is a task-specific, four-bit Qwen 3.5 0.8B model. Its exact weights, training recipe, evaluation harness, and every redistributable training example are public. Training inputs may be manually authored, synthetic, or clearly licensed public material. User Dictations, Target Context, Personal Vocabulary, and private operational data are prohibited training sources.

Gemma 3 1B may be used as a development benchmark challenger. It is not a second product model or user setting.

## Completion Deadline

The public contract is 1.5 seconds from key-up through insertion. Poptart owns a hard watchdog at 1.4 seconds and reserves the final 100 milliseconds for validation and delivery.

Initial M1 engineering budgets are:

| Work after key-up | p99 budget |
| --- | ---: |
| Final recognition | 350 ms |
| Context assembly, deterministic Cleanup, and model decision | 50 ms |
| MLX model input and edit-plan generation | 700 ms |
| Validation and delivery | 100 ms |
| Scheduling and safety margin before watchdog | 200 ms |

The sub-budgets may change after instrumentation; the 1.4-second watchdog and 1.5-second user contract do not.

Cleanup has a model-input token ceiling derived from cold-system M1 benchmarks for each model-pack release. Over-budget Dictations bypass model Cleanup, keep every recognized word, apply deterministic safe rules, and finish normally. The ceiling is not a user setting.

A single Recording stops automatically at five minutes, with a visual warning beginning at 4:30.

## Targeting and insertion

An `InsertionTarget` contains only the minimum ephemeral identifiers required to revalidate the focused application, editable Accessibility element, cursor or selected range, and secure-field state.

Target Context contains:

- application identity or coarse category;
- a bounded slice before the insertion point;
- a bounded slice after the insertion point;
- the selected text when replacement is intended.

It never contains a full document, full window, screenshot, OCR result, unrelated controls, or browser history. It exists only for the active Dictation and is destroyed after completion.

Delivery policy:

1. Block Dictation entirely for secure controls.
2. If no Insertion Target was captured at key-down, replace the system clipboard contents with the completed text, create history, and show the copied result.
3. Revalidate the original target before delivery.
4. Replace the original selection only when it remains valid.
5. Prefer a direct Accessibility value/range write.
6. If direct Accessibility insertion fails while the original target remains focused, use a clipboard-preserving paste transaction.
7. If the target changed, replace the system clipboard contents with the completed text, create history, and show the copied result; do not synthesize paste into the new target.

## Indicator

The Indicator is persistent, compact, nonactivating, and never displays live or completed transcript text. It represents:

- ready;
- unavailable secure target;
- recording with audio activity;
- approaching the five-minute limit;
- finalizing recognition;
- cleaning;
- delivering;
- success;
- Raw Transcript fallback;
- recognition fallback;
- copied because the target changed;
- copied because no Insertion Target was focused;
- failure with no usable text.

Completion and failure states remain visible long enough to be understood, then return to ready without stealing focus.

## Models and offline operation

Onboarding installs one versioned model pack containing compatible recognition and Cleanup artifacts. A signed manifest describes pack identity, app compatibility, artifact URLs, byte sizes, licenses, hashes, and the measured Cleanup token ceiling.

The installer:

1. begins only after explicit user action;
2. supports resumable downloads;
3. verifies the manifest signature using an app-embedded public key;
4. verifies every artifact hash and declared size;
5. stages the complete pack outside the active location;
6. performs a load and smoke test;
7. activates the pack atomically;
8. retains the previous valid pack until activation succeeds;
9. removes invalid or abandoned staged data recoverably where practical.

After onboarding, Poptart makes no background network requests. App-update checks, model-pack updates, and model repair occur only after explicit user action.

Recognition and Cleanup models remain warm for the application lifetime. Cleanup may be released under meaningful macOS memory pressure and loaded again before the next Cleanup opportunity. A fixed residency timer is prohibited.

## Local data and privacy

Audio exists only in bounded memory for the active Dictation and is destroyed after recognition. It is never written to history or diagnostic files.

Each Dictation Record contains:

- identifier and timestamp;
- Raw Transcript when final recognition succeeded;
- the actual inserted or copied text;
- whether Cleanup changed the text;
- outcome/fallback classification;
- local timing measurements;
- destination application identity only at the minimum granularity needed by history UI.

Raw Transcript, delivered text, and sensitive destination fields are encrypted with CryptoKit using a random per-install key stored in Keychain. Plaintext storage is limited to non-sensitive indexing and expiry metadata. Loss of the Keychain key makes encrypted history unrecoverable; Poptart does not upload or escrow it.

History expires after 30 days and offers Clear History. Personal Vocabulary is local, manual, and application-level encrypted. Debug logs must exclude audio, transcript text, Target Context, vocabulary contents, clipboard contents, and encryption keys.

Poptart sends no product-generated request to Playground Labs or a third party unless the person explicitly starts an update, repair, or model download. There is no exception for crash reporting or optional analytics.

## User surfaces

### Onboarding

- product and privacy explanation;
- microphone permission;
- Accessibility permission;
- model-pack size, license, and explicit download;
- offline readiness check;
- right Option shortcut test and optional rebind;
- first Dictation test.

Onboarding is resumable and never reports completion until permissions, the active model pack, and a shortcut test all succeed.

### Settings

- microphone device;
- one Dictation shortcut;
- launch at login;
- model-pack version, storage, explicit check/update/repair;
- Personal Vocabulary;
- history retention explanation and Clear History;
- permission status;
- app version, licenses, source link, and explicit app update check.

### History

- chronological Dictation Records;
- Raw Transcript and actual delivered text;
- visible changed/fallback classification and timings;
- copy action;
- individual deletion and Clear History.

History is a recovery and trust surface, not a training or analytics surface.

## Repository shape

```text
Poptart/
├── App/                         # executable target and composition
├── Packages/
│   ├── DictationCore/
│   ├── AudioCapture/
│   ├── Recognition/
│   ├── Cleanup/
│   ├── Targeting/
│   ├── Insertion/
│   ├── ModelRuntime/
│   ├── Persistence/
│   └── PoptartUI/
├── Models/
│   ├── manifests/               # signed-manifest schema and fixtures
│   └── licenses/
├── Training/                    # reproducible Cleanup training recipe
├── Evals/                       # quality, safety, and latency harnesses
├── Tests/
│   ├── Integration/
│   └── Fixtures/
├── docs/
│   ├── CONTEXT.md
│   ├── FOLLOW-UPS.md
│   ├── architecture/
│   └── adr/
├── LICENSE
├── NOTICE
└── README.md
```

Reused Handy-derived code is copied selectively only after review and retains all required attribution and notices. No Handy manager, command/event, provider, Tauri, React, or cross-platform compatibility layer is carried forward as an architectural foundation.

## Verification and release gates

### Functional

- The state machine accepts only legal transitions and discards late results.
- Key-down/key-up, five-minute stop, permission loss, device loss, app focus changes, selection changes, and cancellation have integration coverage.
- Secure fields never start capture or create history.
- Clipboard-preserving paste restores every represented pasteboard item after successful or failed paste.
- Target changes copy but never paste into the new target.
- A Dictation started with no Insertion Target records, copies to the clipboard, and creates history.
- Every fallback produces the documented Indicator and history outcome.

### Cleanup quality

- The deterministic Explicit Correction suite passes 100%.
- The gold Cleanup set measures exact edit-plan correctness, meaning preservation, vocabulary preservation, and context fit separately.
- An adversarial set covers prompt injection in Raw Transcript and Target Context, Unicode/control characters, invalid spans, overlap, excessive deletion, context copying, and stylistic rewriting.
- No model-pack release ships with a known accepted unsafe edit in the adversarial suite.
- Model regressions are evaluated against the currently shipped pack, not only a fixed absolute score.

### Performance

- On an 8 GB M1 running macOS 15, at least 99% of representative Dictations complete within 1.5 seconds from key-up to delivery under the documented cold-system benchmark.
- Deadline tests include warm models, memory-pressure reload, oversized input, recognition timeout, Cleanup timeout, invalid output, and target-change clipboard delivery.
- App-controlled deadline misses are failures. Operating-system-wide stalls are measured and reported separately.
- Peak and steady-state memory are measured with both models resident on the 8 GB M1 baseline before a model-pack release.

### Privacy and security

- A network deny test proves normal Dictation, history, settings, and model execution work without outbound access.
- A clean-install traffic capture shows network activity only for the explicit model download.
- Persistence tests prove sensitive columns are not recoverable as plaintext from the database or logs.
- Key deletion makes history unrecoverable and produces a safe reset path.
- Model-pack signature, checksum, downgrade/compatibility, interrupted download, and atomic rollback paths have tests.

## Incremental build sequence

1. Create the clean repository, license, notice, CI, local Swift packages, and domain vocabulary.
2. Implement the pure `DictationCore` state machine with fake clocks and fake adapters.
3. Add shortcut, secure-target detection, target capture, direct insertion, paste fallback, and Indicator shell using fakes for speech.
4. Add audio capture and incremental FluidAudio recognition; meet the Raw Transcript deadline before adding Cleanup.
5. Add encrypted history, expiry, vocabulary, and privacy-focused logging.
6. Implement model-pack installation, verification, atomic activation, and warm lifecycle.
7. Build deterministic Explicit Corrections and the Cleanup Edit Plan validator before connecting an LLM.
8. Integrate MLX Swift LM and the stock Qwen baseline, then build the public training/evaluation pipeline.
9. Fine-tune, quantize, benchmark, and select the first Cleanup artifact against Gemma 3 1B.
10. Complete onboarding/settings/history UI, signing, notarization, update flows, security review, and M1 release gates.

Each increment must be usable and testable without depending on unfinished later layers. Cleanup cannot delay proving the recognition-to-insertion foundation.

## Follow-ups

Post-MVP candidates live in `FOLLOW-UPS.md`. They are not latent MVP requirements and must earn separate product and architecture decisions.

## Decision record

The ADR directory contains the confirmed decisions from the design grill. If this specification and an ADR conflict, the newer explicit ADR wins and this document must be updated in the same change.
