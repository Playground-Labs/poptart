# Experimental typed operations

This prototype is used only by Python training/evaluation. The app still accepts
its existing v1 range-based plans. Do not install a v2-trained artifact into the
app: native decoding is not implemented or qualified.

The envelope is `{"v":2,"e":[operations]}` followed by `<END_PLAN>`.
Operations remain in original-source order; the compiler never sorts, repairs,
ignores, or infers an operation.

| Operation | Meaning | Compiled v1 edit |
| --- | --- | --- |
| `{"o":"end","r":"."}` | Add final punctuation after all source spans | `s=N,e=N,r=".",c="punctuation"` |
| `{"o":"delete","i":3,"c":"filler"}` | Delete source span 3 as filler | `s=3,e=4,r="",c="filler"` |
| `{"o":"delete","i":3,"c":"repetition"}` | Delete source span 3 as repetition | `s=3,e=4,r="",c="repetition"` |
| Existing `s,e,r,c` object | Other edits retain the existing representation | Unchanged |

`N` is the number of spans in the original transcript, including spans removed
by other operations. Final punctuation permits only `.`, `?`, or `!`. Deletion
requires a non-boolean integer within the original source and exactly one of the
two listed categories. Other edits remain supported for capitalization, vocabulary,
internal punctuation, and multi-span edits. Supporting a range edit does not
exempt it from validation.

The compiler checks the exact envelope/operation keys, version, operation count,
indices and types. Generated JSON must have unique keys, fit the byte limit and
end exactly at the stop marker. Every compiled plan then goes through the existing
validator mirror, including source-category, protected URL, control-character,
reserved correction, order/overlap, change-budget and context-copy checks. Invalid
plans fall back to raw text; no partial operation is applied.

Training target conversion must round-trip to the original plan exactly. The
compiler does not automatically capitalize based on context or infer sentence
boundaries. This isolates the effects of terminal-boundary and one-token-deletion
encoding while keeping the other responsibilities with the model.
