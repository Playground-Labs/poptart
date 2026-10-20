# Second Cleanup candidate

This experiment uses the same pinned Qwen3.5-0.8B base, LoRA settings, and
4-bit affine export as the first pilot. The corpus grows from 72 to 132 training
records and from 9 to 21 validation records. All original records, including the
8 original test cases, are unchanged. Twelve new holdout cases were authored and
frozen before training in `Training/data/round2-holdout.jsonl`; `holdout.jsonl` is
the run snapshot. No user dictation or application content is included.

New examples cover filler positions, accidental repetitions, punctuation around
questions and statements, reserved deterministic corrections, URLs, numbers, and
intentional repetition. Every target passes the validator mirror and reproduces
its clean text. The maximum training sequence is 408 tokens, and every training
prefix matches non-thinking inference. Normalized training inputs do not overlap
validation, test, gold, or adversarial inputs. The new holdout also has no overlap
with the original corpus or evaluation fixtures.

## Reproduction

Use the Python environment recorded in the first pilot's `requirements.txt`.
The base revision is `2fc06364715b967f1860aea9cf38778875588b17`.
`inputs.json` records input hashes, and `training-arguments.json` contains the
resolved training arguments. This run starts fresh from the base, with no adapter
resumed from the first experiment.

```sh
python3 Training/prepare_corpus.py
.context/cleanup-model/venv/bin/python -m mlx_lm lora \
  --config Training/config/lora.yaml \
  --model .context/cleanup-model/base --data Training/generated/mlx \
  --iters 200 --max-seq-length 512 \
  --adapter-path .context/cleanup-round2/adapters
```

Choose the lower validation loss at step 100 or 200, breaking ties in favor of
100, before evaluating test cases. Put that checkpoint in a new directory as
`adapters.safetensors` with its `adapter_config.json`. Fuse and quantize using the
commands in `Training/README.md`, substituting the new adapter and export paths.
Copy the original base tokenizer files, chat template, and license into the
export. `artifact.json` records the selected adapter hash and all exported files.

Run both the first candidate and the selected candidate through
`CleanupEvaluation` with the same 43 fixtures: gold 12, adversarial 11, original
holdout 8, and new holdout 12. Use the command in `Training/README.md` to reproduce
`comparison.json` from the two saved prediction files.

## Results and decision

Step 200 was selected on validation loss: 0.041 versus 0.057 at step 100.
Both complete 43-case Swift runs exited zero. All 12 fresh holdout prompts match
the Python training prompt builder byte-for-byte, including the reserved
corrections supplied by production code.

| Measure | First candidate | Second candidate |
| --- | ---: | ---: |
| Exact gold output | 5/12 | 6/12 |
| Exact original holdout output | 5/8 | 4/8 |
| Exact new holdout output | 4/12 | 9/12 |
| Strict adversarial fallback | 10/11 | 4/11 |

**Do not promote this candidate for release.** New coverage helped, including both
new correction cases, but the result is a tradeoff rather than a clean
improvement. `comparison.json` lists every exact-output improvement and regression
and reports all four existing quality dimensions separately. Raw generated plans,
actual prompts, and resolved outputs are retained in both prediction files.

Observed regressions and remaining failures:

- Filler deletion often omits capitalization of the following word. This regresses
  `gold-002`, `candidate-filler-012`, and `round2-filler-013`.
- Vocabulary joining is lost in `gold-005` and `candidate-vocabulary-008`.
- Some plans capitalize `I` to the identical `I`, causing the strict validator to
  reject the entire plan. This blocks otherwise useful repetition and punctuation
  edits in the new holdout.
- Commands and fragments still receive question marks, including `gold-009`,
  `gold-012`, and `adv-injection-context`.
- Seven adversarial cases now produce accepted plans. Some only capitalize or add
  a period; others add inappropriate question marks. Existing hidden/control
  characters remain in two outputs. No URL or checksum mutation appears in these
  resolved outputs, but the strict fallback gate is still failed. The criterion
  has not been relaxed.

Next work should preserve the corpus balance for vocabulary and filler-plus-
capitalization, address redundant no-op edits, and expand independent evaluation
for sentence intent. Keep these measured failures in the development history;
a further tuned candidate needs additional unseen cases before release claims.

Verification: 18 Python tooling tests and 20 Swift Cleanup tests pass. The Python
checks validate target plans, data separation, deterministic corpus generation,
and comparison failures for missing or duplicate predictions. Model weights remain
local at `.context/cleanup-round2/candidate-4bit` and are not committed.

## Interpretation limits

The Swift evaluator uses the production engine, parser, validator, and MLX adapter
with greedy non-thinking decoding and 128 output tokens. This is a debug build on
a 36 GB M3 Pro with a diagnostic 30-second deadline and an 8,192 input-token
ceiling. Elapsed times are not release latency measurements. The M1 gate is still
outstanding. Neither model artifact is published or listed in release metadata.

These are small development sets. The new examples and holdout share task
categories, so results do not establish broad generalization. Corpus size and
training duration both changed; this experiment does not isolate their effects.
The original evaluation cases have already informed development. Preserve their
history and use additional unseen evaluation before making release claims.

Exact output includes raw fallbacks when the raw input already matches the target.
The adversarial metric requires fallback even when an accepted edit is harmless.
The existing meaning-preservation and context-fit metrics are deterministic
heuristics, not a human quality review. Inspect generated plans and output text
alongside the aggregate counts. Production derives its own reserved corrections;
the legacy `gold-001` fixture supplies a different reservation to Python, as
noted in the first pilot's runtime report.
