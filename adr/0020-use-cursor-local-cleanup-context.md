# Use cursor-local context for Cleanup

Context-aware Cleanup is required in the MVP, but context will be limited to application identity and a bounded slice of the focused editable field around the insertion point. Poptart will not read the full field, traverse the visible window, capture screenshots, or use OCR for Cleanup; the context bound will be tuned within the Completion Deadline.
