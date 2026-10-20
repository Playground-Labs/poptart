# First Cleanup candidate

Trained on October 5, evaluated after export on October 16, 2026. This is an
experimental artifact, not a release model. The exact local weights are at
`.context/cleanup-model/candidate-4bit`; weights are not committed or published.
`artifact.json` records their SHA-256, size, base revision, adapter hash, input
hashes, and quantization. `training-config.json`, `requirements.txt`, and
`training-metrics.txt` record the run. See `Training/README.md` for reproduction.

The candidate starts from the pinned Qwen base and uses 100 LoRA steps over 72
training records, with 9 validation and 8 test records. Training/validation/test
and gold/adversarial inputs were checked for training overlap. Validation loss
fell from 1.362 to 0.086. The test set was not used to choose a checkpoint.
An earlier run was discarded after finding that the Python prompt encoded an
absent selection as null while Swift omits it. This artifact was trained fresh
on corrected prompts, with no adapters from the discarded run.

## Results

Both models use 4-bit affine quantization, group size 64, the pinned tokenizer,
non-thinking greedy decoding, and a 128-token output budget. Evaluation uses
Python MLX on the 36 GB M3 Pro; it does not enforce a completion deadline.

| Measure | Stock 4-bit | Candidate 4-bit |
| --- | ---: | ---: |
| Exact gold output | 0/12 | 5/12 |
| Accepted gold edit plans | 0/12 | 9/12 |
| Exact gold edit plans | 0/12 | 5/12 |
| Gold meaning-preservation metric | 7/12 | 9/12 |
| Gold vocabulary preservation | 2/2 | 2/2 |
| Gold context-fit metric | 12/12 | 12/12 |
| Exact held-out output | 1/8 | 6/8 |
| Accepted held-out edit plans | 0/8 | 5/8 |
| Strict adversarial fallback metric | 11/11 | 10/11 |

Exact output includes raw fallbacks that already match the expected text. In the
held-out set, one exact output in each column is such a fallback. A fallback-heavy
model can score well on preservation measures while doing no useful Cleanup.
The sample sizes are too small to establish general quality.

## Findings and guard fix

The first evaluation exposed an accepted punctuation edit changing `https://` to
`https:./`. The Swift validator and Python mirror now protect the whole HTTP(S)
URL literal from model replacements, deletions, and insertions, including edits
to path case. This is deliberately conservative at URL boundaries. It is not a
claim that every kind of identifier, address, or numeric literal is protected.

The committed reports/predictions are from fresh inference after that fix. The
URL case now falls back. The one adversarial case still accepted is
`adv-excessive-delete`: its output only capitalizes the first word and adds a
period, preserving all words. The existing metric demands fallback even for
that conservative edit; its criterion has not been changed to improve the score.
Earlier raw reports remain in `.context/cleanup-model/candidate-evaluation`.

The candidate still touches reserved correction spans, returns invalid span
indexes, leaves repetitions behind, and adds inappropriate question marks. Those
errors are visible in the prediction files. The validator catches several but
not all quality errors. **Do not ship this artifact.**

## Verification and next work

- All 17 Python tooling tests pass, including malformed output, train/evaluation
  separation, nil-selection encoding, and URL protection.
- A native executable compiled the actual Swift Cleanup/DictationCore sources and
  rejected 10 URL mutations while accepting 2 adjacent capitalization controls.
  It included an emoji prefix to exercise UTF-16 offsets. Evidence is in
  `.context/cleanup-model/swift-url-guard.log`.
- On October 17, after installing the Xcode Metal toolchain, all 20 Cleanup
  package tests passed, including the URL regression cases.
- Next: expand training coverage for reserved corrections, span boundaries,
  repetition and statement/question distinctions, with new held-out cases; verify
  future exported artifacts through the actual Swift MLX adapter; then qualify
  quality and full-pipeline latency. The M1 release gate remains outstanding.

No production release metadata was populated. The Python measurements are not
Swift runtime parity or M1 release evidence.


## Swift runtime evaluation — October 17

`swift-candidate-predictions.jsonl` records all 31 cases through the production
`CleanupEngine`, `MLXCleanupModel`, parser, and validator. The debug build ran on
the M3 Pro with a diagnostic 30-second per-case deadline and 128 output tokens.
The process exited zero. `swift-candidate-report.json` records scores and source
hashes. This is not a release latency measurement or an M1 benchmark.

Gold exact output remains 5/12 and all five gold/adversarial metrics match the
Python report. Held-out exact output is **5/8**, versus Python's 6/8. For `test-001`,
Swift generated the invalid category `local` and safely fell back to the raw
transcript; Python generated an accepted plan. There are 14 accepted plans and
17 fallbacks overall. These results do not establish exact runtime parity.

The runner lets production code derive reserved correction spans. Python instead
uses any fixture-supplied `reservedEdits`; `gold-001` supplies a correction that
production does not recognize without punctuation around “I mean.” Neither the
fixture nor the production correction rules were changed to improve this score.

The first full run and a one-fixture reproduction wrote their reports but then
exited with SIGSEGV. The adapter ended its output stream at the stop marker while
MLX's worker could still be using resources during shutdown. It now retains the
MLX generation task, cancels and awaits it, and joins outstanding work before
unloading. The fixed full run has identical outputs to the crashing run and exits
cleanly. `Training/test_swift_runtime.py` also passed three consecutive fresh
process runs, checking both the stop marker and exit status. Real-model testing
uses the executable because this Xcode Swift Testing host could not locate MLX's
Metal resource bundle. The ordinary Swift suite and all 17 Python tooling tests
pass independently.
