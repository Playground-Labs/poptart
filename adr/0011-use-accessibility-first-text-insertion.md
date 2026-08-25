# Use Accessibility-first text insertion

Poptart will insert completed text through the macOS Accessibility system when the target exposes a supported editable element. When it does not, Poptart may use a clipboard-preserving simulated paste and then restore the prior clipboard; application-specific insertion hacks are outside the MVP.
