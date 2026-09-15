# Bypass model Cleanup for oversized Dictations

Poptart will not truncate speech or extend the Completion Deadline when a finalized Raw Transcript is too large for reliable model Cleanup. Each supported hardware and model release will define a benchmarked Cleanup input budget. A Dictation exceeding that budget bypasses the Cleanup Managed Model, receives only deterministic Explicit Corrections and safe mechanical processing, and is inserted within the normal deadline. The Indicator and Dictation Record identify this as a size-based fallback. The budget is derived from M1 release measurements rather than exposed as a user setting.

The size-based Fallback decision remains active; ADR 0053 supersedes its Indicator display, leaving the Dictation Record as the only place an oversized Dictation is identified, because the delivered words are already at the insertion point.
