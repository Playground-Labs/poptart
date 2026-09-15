# Block Dictation in secure text fields

Poptart will disable Dictation whenever the focused editable control is identified as secure, including password inputs. It will not read Target Context, begin audio capture, recognize speech, run Cleanup, insert or copy text, or create a Dictation Record for that attempt. The Indicator will show a brief unavailable state without exposing the field's content or other sensitive details.

The secure-field block remains active; ADR 0053 supersedes its brief unavailable Indicator state, which is now the “Not available in a password field” Outcome Toast.
