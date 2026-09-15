# Poptart native voice keyboard

Status: ready for ticketing after creation of the clean repository.

## Problem Statement

People using Poptart need dictated text to appear where they are typing quickly, privately, and in the form they intended to say it. Today, obvious spoken corrections such as “CR, I mean PR” can survive into the inserted text, Cleanup can depend on a separate post-processing interaction, and general-purpose local models can miss the latency cutoff. The result does not yet feel as dependable as keyboard input.

The inherited Handy foundation also carries product and architectural assumptions Poptart no longer wants: a cross-platform Tauri application, provider and model choices, command-oriented behavior, and layers designed for a broader speech-to-text utility. Extending that foundation would make it harder to guarantee native macOS behavior, a strict completion deadline, a small privacy surface, and a single opinionated interaction.

Poptart needs a clean product and code boundary: a macOS-native Voice Keyboard that recognizes and cleans speech entirely on the person’s Mac, completes every app-controlled Dictation path within 1.5 seconds, and preserves trustworthy text whenever AI Cleanup cannot finish safely.

## Solution

Build Poptart again in a clean public repository as a fully native Swift application for Apple Silicon Macs running macOS 15 or newer.

The person holds right Option, speaks, and releases. Poptart recognizes speech incrementally while Recording, finalizes the Raw Transcript at key-up, applies fast deterministic Explicit Corrections, and asks one small task-specific local model for a compact Cleanup Edit Plan. Poptart validates every proposed edit and inserts the cleaned result at the original Insertion Target. If recognition, model Cleanup, validation, or delivery cannot complete safely, Poptart follows a documented deadline-safe Fallback instead of delaying or losing the Dictation.

The product exposes one Conservative Cleanup behavior and one primary shortcut. It has no Command Mode, cloud inference, account, activation, telemetry, or retained audio. Cursor-local Target Context and Personal Vocabulary improve Cleanup without reading an entire document or sending content off the Mac. A persistent transcript-free Indicator makes readiness, Recording, and processing visible through shape alone, and a brief Outcome Toast above it reports only the results a person cannot already see.

The application installs one signed Model Pack during onboarding. That pack contains an English FluidAudio/Parakeet recognition model and a four-bit, task-specific Qwen 3.5 0.8B Cleanup model running in-process through MLX Swift LM. Both models normally remain warm for the application lifetime. The exact Cleanup weights, training recipe, evaluation harness, and redistributable training corpus are public.

## User Stories

1. As a person writing on a Mac, I want to dictate into the application I am already using, so that speech feels like another keyboard input method.
2. As a new Poptart user, I want one obvious Dictation interaction, so that I can become productive without learning modes or commands.
3. As a Poptart user, I want to hold right Option to record and release it to finish, so that microphone state is physically unambiguous.
4. As a Poptart user, I want to rebind the one Dictation shortcut, so that Poptart can fit my keyboard layout and workflow.
5. As a new Poptart user, I want onboarding to test my shortcut, so that I know it works before relying on it in another application.
6. As a Poptart user, I want the Indicator to show that Poptart is ready, so that I know Dictation is available.
7. As a Poptart user, I want the Indicator to react to my voice while Recording, so that I know the microphone is receiving audio.
8. As a privacy-conscious user, I want the Indicator and the Outcome Toast to omit live transcript text, so that nearby people cannot read my Dictation from an overlay.
9. As a Poptart user, I want key-up to end Recording immediately, so that I control exactly what audio belongs to the Dictation.
10. As a Poptart user, I want a visual warning before a five-minute Recording limit, so that a safety stop is not surprising.
11. As a Poptart user, I want Poptart to stop a Recording after five minutes, so that a stuck shortcut cannot leave the microphone active indefinitely.
12. As a Poptart user, I want speech recognition to run while I am speaking, so that little final work remains after key-up.
13. As a Poptart user, I want partial recognition to remain internal, so that unstable words are never presented as completed text.
14. As an English speaker, I want recognition tuned and evaluated for English, so that MVP quality is deliberate rather than nominally multilingual.
15. As a Poptart user, I want text delivered within 1.5 seconds after key-up, so that Dictation does not interrupt my train of thought.
16. As a Poptart user, I want Poptart to stop waiting for AI at 1.4 seconds, so that a better edit cannot violate the delivery promise.
17. As a Poptart user, I want unfinished Cleanup to fall back to the Raw Transcript, so that successful recognition is never discarded.
18. As a Poptart user, I want the latest usable Recognition Hypothesis when final recognition times out, so that I recover more speech than an empty result.
19. As a Poptart user, I want a clear failure when recognition produced no usable text, so that silence is not confused with a successful insertion.
20. As a Poptart user, I want oversized Dictations delivered without truncation, so that the latency promise never costs me spoken words.
21. As a Poptart user, I want oversized Dictations to retain deterministic corrections even when model Cleanup is skipped, so that safe improvements still apply.
22. As a Poptart user, I want Poptart to understand “I mean” self-corrections, so that abandoned wording does not appear in my text.
23. As a Poptart user, I want unmistakable Explicit Corrections handled deterministically, so that common corrections are fast and repeatable.
24. As a Poptart user, I want punctuation and capitalization repaired, so that dictated text is ready to read.
25. As a Poptart user, I want clear filler and accidental repetition removed, so that speech mechanics do not clutter my writing.
26. As a Poptart user, I want Cleanup to preserve my wording and meaning, so that Poptart does not become an unsolicited writing assistant.
27. As a Poptart user, I want one predictable Conservative Cleanup behavior, so that the same speech is treated consistently.
28. As a Poptart user, I want model edits anchored to words I actually dictated, so that the model cannot replace unrelated text.
29. As a Poptart user, I want malformed or excessive edits rejected, so that a model failure cannot corrupt my Dictation.
30. As a Poptart user, I want unchanged words copied deterministically, so that generation time and hallucination risk do not grow with Dictation length.
31. As a Poptart user, I want nearby cursor text to inform mechanics, so that capitalization and punctuation fit the sentence I am editing.
32. As a privacy-conscious user, I want Target Context bounded around the cursor, so that Poptart does not read an entire document.
33. As a privacy-conscious user, I want Poptart to avoid screenshots, OCR, and window traversal, so that context collection remains narrow and auditable.
34. As a Poptart user, I want text found in Target Context treated only as data, so that document content cannot instruct the Cleanup model.
35. As a Poptart user, I want to maintain names, acronyms, and technical terms in Personal Vocabulary, so that Poptart preserves the spelling that matters to me.
36. As a Poptart user, I want one Personal Vocabulary shared by recognition and Cleanup, so that I do not maintain duplicate lists.
37. As a privacy-conscious user, I want vocabulary changes to be manual, so that Poptart does not silently learn from private documents.
38. As a Poptart user, I want Dictation to replace a still-selected range, so that it behaves like normal typing.
39. As a Poptart user, I want Poptart to revalidate the selection before replacement, so that stale selection coordinates never delete unrelated content.
40. As a Poptart user, I want direct Accessibility insertion when the target supports it, so that delivery avoids unnecessary clipboard changes.
41. As a Poptart user, I want paste fallback when direct insertion fails in the same target, so that Dictation works across more Mac applications.
42. As a Poptart user, I want paste fallback to restore my previous clipboard, so that routine Dictation does not destroy copied data.
43. As a privacy-conscious user, I want Poptart to avoid inserting into a newly focused application, so that private speech cannot leak to the wrong destination.
44. As a Poptart user, I want the result copied to the clipboard when the Insertion Target changes, so that my Dictation remains recoverable.
45. As a Poptart user, I want an Outcome Toast when a target change caused clipboard delivery, so that I know to paste manually.
46. As a Poptart user, I want the result copied to the clipboard when no editable field is focused, so that Poptart records my speech instead of refusing it.
47. As a Poptart user, I want an Outcome Toast when a missing editable field caused clipboard delivery, so that I know to paste manually.
48. As a Poptart user, I want no Outcome Toast when the dictated words already appear at my cursor, so that a routine Dictation ends without being told what I can already see.
49. As a privacy-conscious user, I want Dictation blocked in password and other secure fields, so that sensitive entry never enters the speech pipeline.
50. As a privacy-conscious user, I want secure-field attempts omitted from history, so that even blocked sensitive actions leave no text record.
51. As a Poptart user, I want local history to show what recognition heard and what Poptart delivered, so that I can understand Cleanup behavior.
52. As a Poptart user, I want history to identify changed, Raw Transcript, oversized, recognition, and clipboard outcomes, so that every result is explainable.
53. As a Poptart user, I want local stage timings in history, so that I can diagnose slow behavior without sending diagnostics elsewhere.
54. As a Poptart user, I want to copy a prior Dictation from history, so that I can recover text after an insertion problem.
55. As a Poptart user, I want to delete an individual Dictation Record, so that I control retained text.
56. As a Poptart user, I want a visible Clear History action, so that I can remove all retained Dictations immediately.
57. As a privacy-conscious user, I want history to expire after 30 days, so that old Dictations do not accumulate indefinitely by default.
58. As a privacy-conscious user, I want sensitive history and Personal Vocabulary encrypted with a key held in Keychain, so that application data is not stored as readable plaintext.
59. As a privacy-conscious user, I want Target Context destroyed after each Dictation, so that nearby document text never becomes history.
60. As a privacy-conscious user, I want recorded audio discarded after recognition, so that Poptart never becomes an audio archive.
61. As a privacy-conscious user, I want normal startup and Dictation to make no network requests, so that local processing is verifiable.
62. As a privacy-conscious user, I want no analytics, crash uploads, or diagnostics opt-in, so that “privacy-first” has no hidden exception.
63. As a Poptart user, I want no account, activation, or device registration, so that the app remains useful offline and does not identify my Mac.
64. As a new Poptart user, I want onboarding to explain microphone and Accessibility permissions, so that I understand why each permission is needed.
65. As a new Poptart user, I want onboarding to show the Model Pack size and licenses before download, so that network and storage use are explicit.
66. As a new Poptart user, I want a resumable Model Pack download, so that an interrupted connection does not force a complete restart.
67. As a Poptart user, I want model artifacts verified before activation, so that corrupted or substituted files never execute.
68. As a Poptart user, I want recognition and Cleanup models activated together, so that incompatible versions cannot be mixed.
69. As a Poptart user, I want model activation to preserve the last valid pack until the new pack works, so that a failed update does not break offline Dictation.
70. As a Poptart user, I want model repair and updates to begin only when I request them, so that Poptart makes no surprise network connection.
71. As a Poptart user, I want models kept warm while Poptart runs, so that arbitrary residency timers do not make occasional Dictations slow.
72. As a Mac user under memory pressure, I want Poptart to yield model memory when the system needs it, so that the app remains a good platform citizen.
73. As a Poptart user, I want Raw Transcript fallback while a released model reloads, so that memory pressure does not break the completion promise.
74. As a Poptart user, I want settings for the microphone, shortcut, launch at login, Model Pack, permissions, vocabulary, and history, so that core behavior remains manageable without model-provider complexity.
75. As a Poptart user, I want explicit application and Model Pack update checks, so that I control every post-onboarding network action.
76. As an open-source user, I want the application code and Cleanup model artifacts public, so that privacy and behavior can be audited.
77. As an open-source contributor, I want the Cleanup training recipe and evaluation harness, so that model improvements are reproducible.
78. As an open-source contributor, I want training data provenance and redistribution rights documented, so that the public model is legally and ethically reviewable.
79. As an open-source contributor, I want domain modules separated from Apple and model framework adapters, so that behavior can be tested without microphones, UI automation, or loaded models.
80. As an open-source contributor, I want late asynchronous results rejected by Dictation identity, so that concurrency cannot deliver text from an obsolete session.
81. As a release maintainer, I want every release measured on an 8 GB M1, so that the stated minimum hardware has evidence behind it.
82. As a release maintainer, I want at least 99% of representative Dictations delivered within 1.5 seconds, so that latency is a release criterion rather than an aspiration.
83. As a release maintainer, I want privacy, network-deny, model-signature, interruption, and rollback tests, so that local-first behavior survives real failures.
84. As a Playground Labs maintainer, I want the new Poptart to install beside the legacy application during beta, so that testers retain a reliable fallback.
85. As a Playground Labs maintainer, I want no legacy data import, so that the native architecture begins with a clean security and migration boundary.

## Implementation Decisions

### Product and platform

- Create a clean public repository that becomes the canonical Playground Labs Poptart project. Rename and archive the inherited project separately when repository operations are authorized.
- License original new code under MIT. Preserve required notices for any selectively reused Handy-derived code.
- Build for Apple Silicon and macOS 15 or newer. Do not carry cross-platform abstractions into the new architecture.
- Distribute a signed and notarized application directly, outside the Mac App Store sandbox.
- Use a new Playground Labs bundle identifier, application container, Keychain namespace, updater state, permissions identity, and release channel.
- Support side-by-side installation with legacy Poptart during beta.
- Import no legacy settings, history, models, providers, prompts, shortcuts, or vocabulary.

### Interaction and UI

- Use right Option alone as the default press-and-hold shortcut. Expose one configurable Dictation binding.
- Key-down captures the Insertion Target and starts Recording. Key-up ends Recording and starts the Completion Deadline.
- Cap one Recording at five minutes and begin a visual warning at four minutes and thirty seconds.
- Keep one persistent, compact, nonactivating Indicator visible while Poptart runs, at the bottom of the screen just above the Dock.
- Give the Indicator a monochrome shape vocabulary: a blank collapsed sliver when ready, a twenty-one bar waveform during Recording, and a spinner while finalizing, cleaning, and delivering. Color carries no meaning and no outcome has a shape of its own.
- Show state and audio activity only; never show partial or completed transcript text in the Indicator or the Outcome Toast.
- Report a result with a brief Outcome Toast directly above the Indicator. It carries one short fixed message, dismisses itself, and never puts words inside the Indicator.
- Limit the Outcome Toast to the four results a person cannot already see: copied to clipboard, Dictation failed, unavailable in a password field, and thirty seconds left in a Recording. Stay silent for inserted text, for every Fallback that still delivers words, and for cancellation.
- Build onboarding, settings, history, vocabulary, and ordinary windows with SwiftUI.
- Use narrow AppKit adapters for the menu-bar lifecycle, nonactivating Indicator panel, global event taps, Accessibility, window ordering, and text insertion.
- Keep Cleanup in the normal Dictation path. Do not create a separate post-processing shortcut, Command Mode, or model-provider UI.

### Domain orchestration and concurrency

- Put domain types, state transitions, deadline policy, Fallback selection, and outcome classification in a framework-independent `DictationCore` module.
- Make one `DictationSessionActor` the sole writer of active Dictation state.
- Model the normal state progression as ready, recording, finalizing, cleaning, validating, delivering, completed, then ready.
- Represent cleaned insertion, Raw Transcript Fallback, oversized deterministic Fallback, Recognition Hypothesis Fallback, target-changed clipboard delivery, no-target clipboard delivery, empty-recognition failure, secure-target rejection, cancellation, and safety stop as explicit outcomes.
- Give every asynchronous operation a Dictation identifier and discard results that arrive after the session has completed or changed.
- Inject clock, recognition, Cleanup, targeting, insertion, history, and Indicator interfaces into the session boundary.
- Keep audio callback work bounded and real-time safe. Audio callbacks may hand off immutable buffers but may not await UI, storage, or model operations.
- Isolate recognition, Cleanup, Model Pack lifecycle, and history persistence in their own actors.
- Send immutable Indicator snapshots to the main actor rather than exposing mutable session state to UI.

### Audio and recognition

- Capture microphone audio with native AVFoundation facilities and retain it only in bounded memory for the active Dictation.
- Start recognition incrementally during Recording and keep partial hypotheses internal.
- Define a Poptart-owned speech-recognition interface and implement FluidAudio as its first adapter.
- Use FluidAudio Parakeet Unified English 0.6B with its 640 millisecond streaming configuration and int8 encoder for MVP recognition, subject to the physical M1 release gate.
- Finalize the Raw Transcript after key-up. Do not begin model Cleanup on unstable partial hypotheses.
- If final recognition misses the watchdog, deliver the latest nonempty usable Recognition Hypothesis without Cleanup.
- If recognition produces no usable text, insert nothing and return an explicit failure outcome.
- Supply Personal Vocabulary to recognition when the adapter supports biasing without changing the domain contract when it does not.
- Destroy audio immediately after recognition is no longer needed. Never persist recorded audio.

### Cleanup

- Provide one Conservative Cleanup behavior for MVP.
- Permit punctuation, capitalization, clear filler removal, accidental repetition removal, unmistakable self-correction, Personal Vocabulary preservation, and bounded context fit.
- Prohibit summarization, elaboration, tone changes, invented facts, stylistic rewriting, or treating Target Context as instructions.
- Use a hybrid Cleanup pipeline: deterministic logic for unmistakable Explicit Corrections and a local model for ambiguous linguistic and mechanical edits.
- Tokenize the immutable Raw Transcript into stable indexed spans.
- Make deterministic Explicit Corrections authoritative and reserve their spans against conflicting model edits.
- Run one in-process Cleanup Managed Model through a narrow Poptart-owned interface implemented with MLX Swift LM.
- Ship a task-specific, four-bit Qwen 3.5 0.8B model. Gemma 3 1B is a development benchmark challenger, not a product option.
- Ask the model for a versioned, compact Cleanup Edit Plan rather than a regenerated transcript.
- Represent replacements, deletions, casing changes, and punctuation insertions as operations over stable transcript spans.
- Use greedy generation with a tight output cap and stop marker, parse the edit-plan schema incrementally, and reject malformed structures. MLX Swift LM does not provide a stable built-in grammar decoder.
- Validate in-bounds and ordered spans, non-overlap, deterministic reservations, Unicode safety, replacement size, total changed proportion, Conservative Cleanup categories, context non-copying, and deterministic applicability.
- Do not trust model-supplied confidence. Derive acceptance from the plan, validator, deadline, and evaluated behavior.
- Copy every untouched Raw Transcript span deterministically.
- Insert the Raw Transcript whenever model Cleanup times out, fails, or produces an unsafe plan.
- Derive a maximum model-input token budget from M1 release benchmarks for each Model Pack.
- For over-budget Raw Transcripts, skip model Cleanup, preserve all recognized words, and apply only deterministic safe edits.

### Target Context and insertion

- Capture only application identity, a bounded slice before and after the cursor, selected text when relevant, and the identifiers needed to revalidate the original editable element.
- Do not read a full document or window, traverse unrelated controls, take screenshots, perform OCR, or retain Target Context.
- Delimit Raw Transcript, Personal Vocabulary, application category, and Target Context as data fields. Target Context can influence mechanics but cannot become output or instructions.
- Detect secure editable controls before audio capture. Secure targets produce no Recording, text, clipboard output, or Dictation Record.
- If no editable element is focused at key-down, capture no Insertion Target and record the Dictation anyway. Replace the system clipboard contents with the completed Dictation text and report a no-target clipboard outcome.
- Capture a selected range as part of the Insertion Target and replace it only when the same target and range remain valid.
- Revalidate the original Insertion Target before delivery.
- Prefer direct Accessibility insertion.
- If direct insertion fails while the original target remains focused, use a pasteboard transaction that synthesizes paste and restores the previous clipboard contents.
- If the focused application, editable element, or captured selection changed, do not paste into the new target. Replace the system clipboard contents with the completed Dictation text and report a target-changed clipboard outcome.
- Do not add application-specific insertion hacks for MVP.

### Deadline and performance

- Define the Completion Deadline as the interval from key-up through final recognition, Cleanup, validation, and delivery.
- Enforce an app-owned watchdog at 1.4 seconds and reserve the final 100 milliseconds for validation and insertion or clipboard delivery.
- Cancel unfinished recognition or Cleanup when the watchdog fires and select the best safe text available.
- Use initial M1 p99 engineering allocations of 350 milliseconds for final recognition, 50 milliseconds for context/deterministic work/model decision, 700 milliseconds for MLX model input and edit-plan generation, 100 milliseconds for validation and delivery, and 200 milliseconds of scheduling margin.
- Treat those sub-budgets as tunable implementation targets. Keep the 1.4-second watchdog and 1.5-second public contract fixed.
- Require at least 99% of representative Dictations to complete within 1.5 seconds on an 8 GB M1 under the documented cold-system benchmark.
- Measure operating-system-wide stalls separately from app-controlled deadline misses.

### Model Pack and runtime lifecycle

- Install recognition and Cleanup artifacts together as one versioned Model Pack during onboarding.
- Fetch the pack from a Playground Labs-controlled signed manifest only after explicit user action.
- Include identity, app compatibility, artifact locations, byte sizes, licenses, cryptographic hashes, and the measured Cleanup token ceiling in the manifest.
- Support resumable artifact downloads.
- Verify the manifest signature with an application-embedded public key, then verify every artifact size and hash.
- Stage and smoke-test the complete pack before activation.
- Activate recognition and Cleanup artifacts atomically and retain the previous valid pack until activation succeeds.
- Keep both models resident for the running application lifetime.
- Release Cleanup only under meaningful macOS memory pressure, never because a residency timer expired.
- Prewarm a released Cleanup model during the next Recording and preserve Raw Transcript Fallback if reload is incomplete.
- Permit app update checks, Model Pack updates, and repair only after explicit user actions. Make no background network request after onboarding.

### Model development and openness

- Publish the exact quantized Cleanup weights, training recipe, evaluation harness, and all redistributable training examples.
- Use only manually authored, synthetic, or clearly licensed public training data.
- Prohibit user Dictations, Target Context, Personal Vocabulary, and private product data from collection or training.
- Record provenance and licensing for every public training source.
- Compare the fine-tuned Qwen artifact with the stock baseline and Gemma challenger on the same quality, safety, latency, and memory harness.
- Require the selected artifact to pass product release gates; do not weaken the Completion Deadline to accommodate the model.

### Persistence and privacy

- Store a Dictation Record containing the finalized Raw Transcript when available, actual delivered text, Cleanup-changed flag, outcome/Fallback classification, and local stage timings.
- Do not retain Target Context in history.
- Encrypt Raw Transcript, delivered text, sensitive destination data, and Personal Vocabulary at the application level with CryptoKit.
- Generate a random per-install encryption key and store it in macOS Keychain. Do not upload or escrow the key.
- Keep plaintext persistence limited to non-sensitive metadata required for ordering, expiry, and outcome filtering.
- Treat loss of the Keychain key as unrecoverable history and provide a safe local reset path.
- Expire Dictation Records after 30 days and expose individual deletion and Clear History.
- Exclude audio, transcripts, Target Context, Personal Vocabulary contents, clipboard contents, and keys from logs.
- Send no analytics, usage events, performance data, diagnostics, crash reports, audio, text, vocabulary, or context to Playground Labs or third parties.
- Require no account, sign-in, activation, license check, or device registration.

### Repository and module design

- Use local Swift packages to enforce domain, adapter, persistence, and UI boundaries.
- Separate application composition, Dictation domain logic, audio capture, recognition, Cleanup, targeting, insertion, Model Pack lifecycle, persistence, and UI into focused modules.
- Make domain-owned protocols the dependency direction for FluidAudio, MLX Swift LM, AppKit, Accessibility, Keychain, and persistence adapters.
- Build each increment around usable behavior: domain state machine; shortcut and insertion shell; Raw Transcript recognition; encrypted history; Model Pack lifecycle; deterministic Cleanup and validator; MLX model; fine-tuned artifact; complete UI and release pipeline.
- Reuse legacy code only after isolated review and required attribution. Do not reuse the manager, Tauri command/event, provider, React, or cross-platform architecture.

## Testing Decisions

- Use one primary behavioral seam: drive a complete `DictationSession` through injected input events, fake time, and fake system adapters, then assert only observable outcomes.
- Observable outcomes are delivered or copied text, Indicator snapshots, Outcome Toast messages, requested history writes, outcome/Fallback classification, cancellation, and elapsed deadline behavior.
- Do not assert actor scheduling, private helper calls, prompt-builder implementation, internal state storage, or framework-specific method invocation from the primary behavior suite.
- Use a deterministic fake clock. No deadline behavior test may wait on wall-clock sleeps.
- Use scripted recognition and Cleanup adapters capable of returning success, partials, timeouts, cancellation, malformed plans, unsafe plans, and late results.
- Exercise the full state progression and every documented terminal outcome through the primary seam.
- Verify that a Dictation identifier prevents late recognition or Cleanup results from affecting a later session.
- Verify key-down, key-up, auto-repeat, duplicate events, lost key-up protection, rapid consecutive Dictations, and the five-minute safety stop.
- Verify that secure controls stop before audio capture and create no clipboard or history effect.
- Verify still-valid and changed applications, fields, cursors, and selected ranges.
- Verify direct insertion success, Accessibility failure with clipboard-preserving paste, paste timeout, clipboard ownership changes, and target-change copy behavior.
- Verify that a Dictation started with no editable target records, copies to the clipboard, and creates a Dictation Record.
- Verify successful Cleanup, Raw Transcript Fallback, Recognition Hypothesis Fallback, empty recognition, oversized deterministic Fallback, model timeout, invalid schema, bad spans, overlap, excessive edits, blank output, and cancellation.
- Verify that an Outcome Toast appears for exactly the four documented results and that every other outcome, including each Fallback that still delivers words, produces none.
- Verify the watchdog at the boundary immediately before, at, and immediately after 1.4 seconds, plus final delivery within 1.5 seconds.
- Test Explicit Correction parsing and Cleanup Edit Plan validation as pure behavioral components with table-driven gold and adversarial examples.
- Require the deterministic Explicit Correction corpus to pass completely.
- Measure model behavior separately for exact plan correctness, meaning preservation, Personal Vocabulary preservation, context fit, unsafe-edit acceptance, and fallback rate.
- Include adversarial examples containing prompt injection in Raw Transcript and Target Context, hidden Unicode, control characters, URLs, numbers, context-copy attempts, excessive deletion, overlapping spans, and stylistic rewrites.
- Add contract tests around FluidAudio for partial/final ordering, cancellation, vocabulary capability reporting, audio release, and error translation.
- Add contract tests around MLX for local artifact loading, bounded edit-plan parsing, cancellation, warm reuse, memory-pressure unload, and late completion.
- Add macOS integration tests for secure-field detection, Accessibility target capture/revalidation, selected-range replacement, nonactivating Indicator and Outcome Toast behavior, and pasteboard restoration.
- Add Model Pack integration tests with a local HTTP server for fresh and resumed downloads, valid and invalid ranges, interruption, cancellation, size limits, hash mismatch, manifest-signature failure, incompatible versions, smoke-test failure, atomic activation, and rollback.
- Add persistence tests proving sensitive values are not present as plaintext, expiry works, individual and bulk deletion work, Keychain key loss makes old records unreadable, and reset recovers a usable empty store.
- Add network-deny tests proving normal startup, Dictation, settings, history, vocabulary, and inference work without outbound access.
- Capture clean-install network traffic and require that only the explicit Model Pack download occurs.
- Run performance tests on a physical 8 GB M1 with representative short, medium, corrected, context-aware, oversized, model-fallback, recognition-fallback, warm, and memory-pressure-reload cases.
- Report p50, p95, p99, maximum app-controlled duration, model input/output tokens, memory, and Fallback class. Gate release on p99 rather than cached repeated-prompt best cases.
- Test the exact production prompt, tokenizer, quantized artifact, framework versions, and Model Pack layout. Do not substitute an optimistic benchmark harness.
- Treat the legacy project’s shortcut event simulations, transcript finalization/Fallback cases, unsafe-output checks, clipboard transaction state tests, and resumable verified-download tests as behavioral prior art only.
- Do not port legacy tests mechanically. Re-express their externally valuable cases through the new DictationSession seam and focused native adapter contracts.
- Require unit and integration tests in CI on every change. Run physical-device privacy, performance, Accessibility, signing, and notarization gates before release.

## Out of Scope

- Voice commands, agents, instruction execution, transforms, or Command Mode.
- A separate post-processing shortcut or opt-in Cleanup command.
- Cleanup Off, Light, Polish, or other user-selectable strength levels.
- Stylistic rewriting, summarization, tone adjustment, or content generation.
- Cloud recognition or Cleanup.
- Accounts, authentication, activation, subscriptions, license servers, or device registration.
- Analytics, crash reporting, performance uploads, or any diagnostics opt-in.
- Retained recorded audio.
- Live partial transcript display.
- Full-field or full-document context, window traversal, screenshots, OCR, or browser-history access.
- Automatic Personal Vocabulary learning.
- Snippets or spoken phrase expansion.
- Multiple recognition or Cleanup model choices.
- Multilingual recognition or Cleanup in MVP.
- Intel Mac support or macOS releases before Sequoia.
- Windows and Linux applications.
- Mac App Store distribution.
- A complete offline installer containing the Model Pack.
- Toggle-style Recording.
- Configurable or indefinite history retention.
- Legacy settings, history, models, prompts, providers, shortcuts, or vocabulary migration.
- Application-specific insertion hacks.

## Further Notes

- The product and architecture direction was confirmed after a detailed design grill and is backed by 50 local ADRs plus a domain glossary and runtime architecture diagram.
- This specification deliberately restates those decisions in product-spec format. The detailed architecture specification remains the deeper source for module boundaries, timing allocations, privacy rules, and the incremental build sequence.
- The Cleanup Edit Plan schema is logical rather than a frozen serialized representation. Prototype and benchmark work may refine encoding as long as compact span-anchored edits, deterministic copying, validation, and Fallback semantics remain intact.
- The numerical Cleanup token ceiling is intentionally absent. It must be produced by the exact production Model Pack on the M1 baseline and stored as pack metadata.
- “Always within 1.5 seconds” is enforced for app-controlled work through the watchdog and Fallback policy. Operating-system-wide stalls are measured separately because the application cannot make an absolute real-time guarantee on macOS.
- Issue-tracker publication and the `ready-for-agent` label are deferred because the clean canonical repository does not yet exist and the current workflow is local-only. When that repository is created, publish this spec there without reopening resolved product decisions.
