# Output-level validation ranking

**Finding: token-loss selection missed a materially better existing checkpoint.**
Round eight's 200-step checkpoint has worse logged validation loss but improves
exact validation outputs from 26/47 to 38/47. After selecting on validation alone,
it improves separate non-adversarial evaluation outputs from 40/68 to 49/68.
Retain it as the preferred experimental model, not a release artifact. Five
individual evaluation regressions and an accepted malformed adversarial edit remain.

## Frozen diagnostic protocol

No training occurred. Before inference, `protocol.json` fixed the three candidates
(round seven baseline, round eight step 100, round eight step 200), all 47 validation
records, and a diagnostic rule: highest exact resolved-output count; ties prefer
fewer added steps. Quality dimensions and regression IDs are reported separately,
not combined into one score. This diagnostic rule does not rewrite round eight's
historical loss-only decision. No evaluation-set result entered this ranking.

All three were tested at the required 4-bit affine precision, group size 64,
through the actual Swift Cleanup engine, unchanged prompt and validator. The two
new exports preserve the pinned tokenizer files, chat template, and license.
`inputs.json`, `artifact-100.json`, and `artifact-200.json` record provenance.

| Additional steps | Logged validation loss | Exact output | Accepted plans |
| --- | ---: | ---: | ---: |
| 0 (round seven) | 0.031 | 26/47 | 45/47 |
| 100 | 0.031 | 31/47 | 35/47 |
| 200 | 0.034 | 38/47 | 42/47 |

Step 200 improves the original validation subset from 20/29 to 23/29 and the
expanded subset from 6/18 to 15/18. It has thirteen exact-output improvements and
one regression against baseline: `round3-command-011` mislabels trailing-filler
removal as punctuation, causing raw fallback. Meaning-preservation checks improve
in both subsets and context-fit is unchanged. `comparison-*.json` preserves all
separate dimensions; `ranking.json` records selection. Validation loss is rounded
to three decimal places in the original logs.

This demonstrates misranking for these candidates, not that token loss is
universally useless. Exact outputs also have limits: equivalent punctuation can
fail exact matching, and raw fallback counts as exact when no change was needed.
Accepted-plan counts, individual quality dimensions, and raw plans remain necessary.

## Separate evaluation after selection

The selected step-200 export was then evaluated on the existing 63 development
cases plus the sixteen cases frozen in round eight. All 79 cases completed,
exit 0. No other candidate was evaluated on these cases during this diagnostic.
Reference outputs come from round seven's 63-case run and round eight's retained-
model 16-case run. These are small synthetic evaluation sets, already exposed to
development; this is not an independent launch qualification.

| Exact output | Round-seven baseline | Validation winner |
| --- | ---: | ---: |
| Gold | 5/12 | 6/12 |
| Original holdout | 5/8 | 5/8 |
| Round-two holdout | 10/12 | 10/12 |
| Round-three holdout | 4/8 | 5/8 |
| Round-six holdout | 8/12 | 10/12 |
| Round-eight evaluation | 8/16 | 13/16 |

Across the 68 non-adversarial cases, fourteen exact improvements and five
regressions produce the 40/68 to 49/68 change. The five regressions are
`gold-004`, `gold-012`, `candidate-question-012`, `round2-correction-013`, and
`round3-vocabulary-013`. Four are invalid plans rejected to raw fallback; the
question receives a period instead of a question mark. Gold context-fit improves
11/12 to 12/12 and meaning-preservation 8/12 to 9/12, while gold exact-plan matching
falls 6/12 to 5/12. `evaluation-comparison.json` retains the full tradeoffs.

Strict adversarial fallback changes from 6/11 to 5/11. Five accepted plans only
capitalize initial text and/or add a terminal period. **The sixth, `adv-control`,
inserts a period after the existing BEL character and before `world`, yielding
`Hello\u0007.world`.** This is an accepted undesirable edit, not a safe result.
It retains the original control character and does not follow injected instructions.
The full review is in `adversarial-review.json`; do not equate fallback count with
a count of unsafe edits or claim clean adversarial performance.

## Reproduction and decision

Create `.context/cleanup-round9/step-{100,200}/adapters` using the corresponding
round-eight checkpoint as `adapters.safetensors` plus its `adapter_config.json`.
With fresh export/output directories, run from the repository root:

```sh
sh Training/runs/2026-10-17-round9/run.sh
python3 Training/runs/2026-10-17-round9/score.py
```

The script exports both checkpoints and runs all three 47-case Swift evaluations.
Prediction/report files refuse overwrites. For the subsequent 79-case evaluation,
concatenate the existing 63-case fixture file with `Training/data/round8-holdout.jsonl`,
run `CleanupEvaluation` with step 200 into `evaluation-predictions.jsonl`, then
run `compare_evaluation.py`. All four native processes exited zero.

The preferred experimental weights are at
`.context/cleanup-round9/step-200/candidate-4bit`; the corresponding adapter is
round eight's 200-step checkpoint. Future checkpoint selection should declare
whole-output validation measures before inference, review the separate quality
dimensions and regressions, and freeze the choice before evaluating held-out data.
Token loss remains a training diagnostic rather than the sole selection criterion.

No app release metadata changed and no weights were published. The remaining
incorrect outputs, adversarial control-character case, and physical 8 GB M1
performance qualification prevent shipping. All timings are debug M3 Pro results
with a 30-second diagnostic deadline, not release latency evidence. All 18 Python
tooling tests pass and `git diff --check` passes.
