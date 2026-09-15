# Poptart

Poptart is a macOS-first, local-first voice keyboard that turns speech into text at the user's current insertion point.

## Language

**Voice Keyboard**:
A system-wide input tool that converts a person's speech into text for the application they are using.
_Avoid_: Voice assistant, voice agent

**Local-first**:
Speech and text processing occur on the person's Mac. Network access is limited to explicit software and Managed Model installation, update, or repair actions.
_Avoid_: Cloud-first, offline-only

**Privacy-first**:
Poptart collects and transmits no usage data or user-generated content; private inputs and operational measurements remain on the person's Mac.
_Avoid_: Anonymous analytics, opt-out telemetry

**Dictation**:
One recording interaction that produces text at the current insertion point, or on the system clipboard when no Insertion Target is focused.
_Avoid_: Recording job, transcription request

**Recording**:
The interval during which the primary shortcut is held and Poptart captures microphone audio for one Dictation.
_Avoid_: Session, listening mode

**Cleanup**:
The normal final editing of a raw transcript into the speaker's intended text, including punctuation, filler removal, and explicit speech corrections.
_Avoid_: Post-processing, formatting mode

**Explicit Correction**:
A spoken replacement whose correction marker unambiguously identifies earlier wording as abandoned and later wording as intended.
_Avoid_: Command, rewrite request

**Conservative Cleanup**:
Cleanup that preserves the speaker's wording and meaning while correcting mechanics, clear filler or repetition, and speech corrections.
_Avoid_: Polish, rewrite, improve writing

**Cleanup Edit Plan**:
A compact set of model-proposed edits anchored to stable spans of a Raw Transcript. Poptart validates and applies the plan while copying all untouched text deterministically.
_Avoid_: Rewritten transcript, model response

**Raw Transcript**:
The text produced directly by speech recognition before Cleanup changes it.
_Avoid_: Failed transcript, unprocessed result

**Recognition Hypothesis**:
The latest usable but not fully finalized text from incremental recognition. It is delivered only when final recognition misses the Completion Deadline.
_Avoid_: Raw Transcript, partial result

**Completion Deadline**:
The maximum time from the end of recording until Poptart inserts text, including final recognition, Cleanup, validation, and insertion.
_Avoid_: Model timeout, cleanup timeout

**Insertion Target**:
The focused editable location captured for a Dictation and revalidated before Poptart writes its result.
_Avoid_: Active app, destination window

**Target Context**:
A bounded, ephemeral slice of text surrounding the Insertion Target, plus application identity, used only to make Cleanup fit the destination.
_Avoid_: Window context, screen context, conversation history

**Clipboard Dictation**:
A Dictation started with no Insertion Target, whose completed text is placed on the system clipboard instead of inserted into a field.
_Avoid_: Clipboard mode, target-change copy

**Personal Vocabulary**:
The person's manually curated names, acronyms, and technical terms that guide both recognition and Cleanup.
_Avoid_: Custom words, learned vocabulary, dictionary

**Indicator**:
The compact, persistent visual signal that shows Poptart is ready and communicates the state of the active Dictation.
_Avoid_: Overlay window, HUD, widget

**Outcome Toast**:
The brief message shown above the Indicator that names how a Dictation ended when the person cannot already see that result on screen. It carries one of a fixed set of short messages and never live or completed transcript text.
_Avoid_: Notification, alert, status text

**Managed Model**:
A versioned inference asset that Poptart selects, installs, verifies, and operates without asking the person to manage model technology.
_Avoid_: User model, provider model

**Model Pack**:
A signed, versioned, atomically activated set containing compatible recognition and Cleanup Managed Models plus their licenses and runtime metadata.
_Avoid_: Model bundle, provider installation

**Fallback**:
A documented deadline-safe outcome that preserves the best trustworthy text available when the preferred recognition, Cleanup, or insertion path cannot complete safely.
_Avoid_: Silent failure, degraded mode

**Dictation Record**:
The local history entry for one Dictation, containing what recognition heard, what Poptart inserted, and the Cleanup outcome.
_Avoid_: History item, transcription log
