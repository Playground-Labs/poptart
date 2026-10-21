# Uniform-discriminator follow-up

This experimental Python format is not supported by the application. The app
continues to use its existing v1 edit plans.

The only schema difference from the hybrid experiment is that a range operation
must explicitly declare `"o":"edit"`:

```json
{"v":2,"e":[{"o":"edit","s":0,"e":1,"r":"Bring","c":"capitalization"},{"o":"delete","i":3,"c":"filler"},{"o":"end","r":"."}]}
```

For source `bring the rope um`, this compiles to capitalization of span0, deletion
of span3, and punctuation at original boundary4. The expected result is
`Bring the rope.`. The compiler removes only the exact `o:edit` discriminator
before delegating to the already-tested hybrid compiler and validator mirror.
It never drops an edit, guesses an index, or repairs an invalid plan.

All operations require a discriminator. `edit` requires exactly `o,s,e,r,c`;
`end` and `delete` keep their previous strict keys/types. Raw discriminator-free
range edits now fail closed. Versions, duplicate keys, byte/operation limits,
category safety, reserved edits, order, protected URLs and substantive wording
remain checked. The same stop marker and128-output-token limit apply.

The training system instruction differs only in its example for other edits,
adding `o:edit`; data, target semantics, source order and100-step settings match
the prior hybrid arm. The same v2 envelope is intentionally retained to avoid
changing the version token as another variable. These incompatible experimental
v2 variants are distinguished by their explicit compiler/prompt, not a production
manifest. Neither may be installed in the app.
