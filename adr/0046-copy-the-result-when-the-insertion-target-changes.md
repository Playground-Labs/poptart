# Copy the result when the Insertion Target changes

If the focused application, editable element, or captured selection changes during Dictation, Poptart will not automatically insert text into the new target. It will place the completed Dictation text on the system clipboard, retain the outcome in encrypted history, and show a clear copied-to-clipboard Indicator state. This target-change behavior intentionally replaces the previous clipboard contents. Clipboard-preserving paste remains the technical fallback only when the original Insertion Target is still focused but direct Accessibility insertion fails.

The target-change copy decision remains active; ADR 0053 supersedes its copied-to-clipboard Indicator state, which is now the “Copied to clipboard” Outcome Toast shown above a wordless Indicator.
