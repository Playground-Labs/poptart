# Keep Managed Models resident until memory pressure

Poptart will normally keep both recognition and Cleanup Managed Models resident for the lifetime of the running application rather than unloading them on a timer. The Cleanup model may be released when macOS reports meaningful memory pressure; the next Recording then prewarms it, with Raw Transcript fallback preserving the Completion Deadline if reloading is incomplete.
