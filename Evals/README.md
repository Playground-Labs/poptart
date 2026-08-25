# Cleanup evaluation

The checked-in gold and adversarial fixtures are authored synthetic data under CC0-1.0. `run.py` always validates provenance, uniqueness, deterministic gold transformations, and required adversarial coverage. With `--predictions`, it additionally scores an exact production-model result file; without predictions it reports `fixture-integrity` and makes no model-quality claim.

Prediction JSONL records use `{"id":"...","output":"...","outcome":"cleaned|fallback","elapsedMilliseconds":123.4}`. Release evidence must identify the exact prompt, tokenizer, quantized artifact SHA-256, runtime pins, hardware, OS, and invocation. Results from the deterministic fixture-integrity mode cannot satisfy the quality or M1 release gate.
