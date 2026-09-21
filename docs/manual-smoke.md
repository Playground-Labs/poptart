# Representative manual smoke test

Automation covers the control classes. `Tools/Compat` drives the real capture and
delivery path against every editable control class we claim to support, so
compatibility is not established by testing application after application.

This list is deliberately small. It covers only what the harness cannot reach:
real speech, real permission grants, real window-server behaviour, and a thin
sample of the application families whose Accessibility implementations differ
most. If a check here fails, the fix belongs in the harness as a new control
class or assertion — not in a longer manual list.

Record each result inline with a date and build. A blank result is not a pass.

## Prerequisites

- A build launched through `Scripts/dev-run.sh` (ad-hoc signed so the
  permission grants survive a rebuild).
- A complete development Model Pack with recognition and Cleanup assets, plus its
  `manifest.json` and positive Cleanup token ceiling. An incomplete Cleanup directory
  with a declared ceiling fails startup; it is not a successful fallback test.
- Use the DEBUG `POPTART_SUPPORT_DIRECTORY` override with a fresh test directory to
  isolate history, vocabulary, settings, and the Keychain service from normal use.
  `POPTART_MODEL_PACK_DIRECTORY` selects the unpacked development pack. These variables
  must reach the app process; see the isolated launch in `Scripts/privacy/network_deny.sh`.

A DEBUG pack without a declared Cleanup ceiling deliberately bypasses model Cleanup.
That can exercise raw-transcript delivery, but does not verify Cleanup or qualify a
release. Record the build, exact pack, ceiling, and whether Cleanup ran with each result.

## Checks

### 1. First run reaches a working state
Launch with no prior grants. Onboarding must request microphone, Accessibility,
and Input Monitoring, must not report completion before all three plus an active
pack and a passed shortcut test, and must resume where it left off if quit
mid-flow.
Result:

### 2. Speech becomes text at the insertion point
In TextEdit, hold the shortcut, speak one sentence, release. The transcript
appears at the caret within about a second and a half. This is the only check
that exercises the microphone, the recognizer, and delivery together.
Result:

### 3. Representative application families
One dictation each, confirming text lands verbatim in the focused control:
- Native AppKit text view — TextEdit or Notes
- Browser — Safari address bar, then a `<textarea>` on any local page
- Chromium/Electron — VS Code or Slack
- Terminal — Terminal.app prompt
These four families cover the Accessibility implementations that differ in
practice. Anything beyond them belongs in the harness.
Result:

### 4. A secure field is refused
Focus a password field (System Settings authentication prompt, or any login
form) and hold the shortcut. Recording must not begin, an Outcome Toast must
report that Dictation is not available in a password field, and no history entry
may appear.
Result:

### 5. The Indicator behaves
It never shows transcript text, never steals focus from the app being typed
into, and returns to ready after a completed or failed dictation.
Result:

### 6. The five-minute safety stop
Begin a recording and hold. A visual warning appears at 4:30 and recording stops
on its own at 5:00, delivering whatever was recognised rather than discarding it.
Result:

## Out of scope here

Deadline and memory measurements belong to the declared physical Apple Silicon benchmark, not to this
list. The privacy checks are `Scripts/privacy/network_deny.sh` and
`Scripts/privacy/traffic_capture.sh`; their prerequisites and evidence limits are
in `Scripts/README.md`. A startup-only deny run does not prove offline Dictation.
Cleanup quality is measured by the evaluation harness against a trained artifact.
