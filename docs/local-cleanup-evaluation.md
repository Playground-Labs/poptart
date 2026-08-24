# Local cleanup model evaluation

Run the benchmark manually; it is intentionally excluded from CI:

```bash
bun run evaluate:cleanup -- --models gemma3:4b,qwen3:8b --runs 5 --output cleanup-report.json
```

The versioned corpus covers explicit and implicit corrections, destructive false positives, formatting, multilingual dictation, cursor-context proper nouns, blanks, and injection-shaped speech. Reports include native Ollama phase timings, cold and warm latency, fallback rate, changed-token ratio, context quality, quantization, model and resident-memory sizes, thermal readings, baseline regressions, runtime, operating system, and hardware metadata.

Keep `gemma3:4b` as the default unless a candidate has no high-severity quality regression and reaches warm p50 ≤ 700 ms and p95 ≤ 1.2 s on named supported Apple-silicon hardware. The report captures the model metadata, memory, cold-start behavior, thermal conditions, context quality, and timeout policy needed for that decision.
