# Recognize speech incrementally during Recording

Poptart will feed audio into speech recognition while the shortcut is held so release requires only recognition finalization, Cleanup, validation, and insertion. Partial recognition remains internal and is never displayed or inserted, preserving a stable user-visible result while protecting the 1.5-second Completion Deadline.
