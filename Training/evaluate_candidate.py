#!/usr/bin/env python3
"""Exploratory Python MLX evaluation; not Swift runtime or release qualification."""

import argparse
import hashlib
import importlib.metadata
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Training"))
sys.path.insert(0, str(ROOT / "Evals"))

import editplan
import prepare_corpus
import run as evaluation


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def resolve_output(record, generated):
    """Fail closed using the existing validator mirror; keep the rejected bytes."""
    try:
        if not generated.endswith(editplan.STOP_MARKER):
            raise ValueError("incomplete or trailing output")
        body = generated[:-len(editplan.STOP_MARKER)]
        if len(body.encode("utf-8")) > 8192:
            raise ValueError("plan byte limit")
        document = json.loads(body, object_pairs_hook=unique_keys)
        edits = editplan.parse_plan(document)
        reserved = record.get("reservedEdits", [])
        violation = editplan.plan_violation(
            edits, record["raw"], record.get("vocabularyTerms", []), reserved,
            record.get("targetContext", editplan.DEFAULT_TARGET_CONTEXT),
        )
        if violation:
            raise ValueError(violation)
        return {"outcome": "cleaned", "output": editplan.resolve(record["raw"], edits, reserved),
                "editPlan": document, "rejection": None}
    except (ValueError, KeyError, TypeError) as error:
        return {"outcome": "fallback", "output": record["raw"], "rejection": str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    args = parser.parse_args()
    if not args.model.is_dir():
        parser.error("--model must be an existing local model directory")
    args.output.mkdir(parents=True, exist_ok=False)

    import mlx.core as mx
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    gold = evaluation.load(ROOT / "Evals/fixtures/gold.jsonl")
    adversarial = evaluation.load(ROOT / "Evals/fixtures/adversarial.jsonl")
    evaluation.validate_fixtures(gold, adversarial)
    holdout = [row for row in evaluation.load(prepare_corpus.SOURCE) if row["split"] == "test"]
    for row in holdout:
        row["expected"] = row["clean"]
    model, tokenizer = load(str(args.model.resolve()), tokenizer_config={"trust_remote_code": False})
    rows = []
    for original in gold + adversarial + holdout:
        record = dict(original)
        if isinstance(record.get("targetContext"), str):
            record["targetContext"] = {**editplan.DEFAULT_TARGET_CONTEXT,
                                       "textBeforeCursor": record["targetContext"]}
        messages = [
            {"role": "system", "content": prepare_corpus.SYSTEM},
            {"role": "user", "content": prepare_corpus.user_message(record, editplan.tokenize(record["raw"]))},
        ]
        start = time.perf_counter()
        prompt = tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True,
                                               enable_thinking=False, return_dict=False)
        generated = ""
        token_count = 0
        stream = stream_generate(model, tokenizer, prompt=prompt, max_tokens=128, sampler=make_sampler(temp=0))
        try:
            for response in stream:
                generated += response.text
                token_count += 1
                # Preserve the entire chunk, including invalid trailing bytes, just as Swift does.
                if editplan.STOP_MARKER in generated:
                    break
        finally:
            stream.close()
        result = resolve_output(record, generated)
        elapsed = (time.perf_counter() - start) * 1000
        row = {"id": record["id"], **result, "elapsedMilliseconds": elapsed,
               "generated": generated, "inputTokens": len(prompt), "outputTokens": token_count}
        rows.append(row)
        print(f"{record['id']}: {result['outcome']}, {elapsed:.0f} ms", flush=True)
    predictions = {row["id"]: row for row in rows}
    fixture_ids = {row["id"] for row in gold + adversarial}
    (args.output / "predictions.jsonl").write_text("".join(
        json.dumps(row, ensure_ascii=False) + "\n" for row in rows if row["id"] in fixture_ids
    ))
    (args.output / "holdout.jsonl").write_text("".join(
        json.dumps(row, ensure_ascii=False) + "\n" for row in rows if row["id"] not in fixture_ids
    ))
    report = {
        "schemaVersion": 1,
        "releaseQualified": False,
        "scope": "Python MLX, 128 output tokens, no deadline; Swift parity and physical M1 outstanding",
        "hardware": subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "physicalMemoryBytes": int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True)),
        "os": platform.platform(),
        "runtimeVersions": {name: importlib.metadata.version(name) for name in ("mlx", "mlx-lm", "transformers", "tokenizers")},
        "modelFilesSHA256": {p.name: digest(p) for p in sorted(args.model.iterdir())
                             if p.suffix in (".json", ".safetensors", ".jinja")},
        "inputsSHA256": {str(p.relative_to(ROOT)): digest(p) for p in (
            prepare_corpus.SOURCE, ROOT / "Training/prepare_corpus.py", Path(__file__).resolve(),
            ROOT / "Evals/editplan.py", ROOT / "Evals/run.py",
            ROOT / "Evals/fixtures/gold.jsonl", ROOT / "Evals/fixtures/adversarial.jsonl")},
        "fixtures": evaluation.score(gold, adversarial, predictions),
        "holdout": evaluation.score(holdout, [], predictions),
        "goldExactOutput": sum(predictions[r["id"]]["output"] == r["expected"] for r in gold),
        "holdoutExactOutput": sum(predictions[r["id"]]["output"] == r["expected"] for r in holdout),
        "goldAcceptedPlans": sum(predictions[r["id"]]["outcome"] == "cleaned" for r in gold),
        "holdoutAcceptedPlans": sum(predictions[r["id"]]["outcome"] == "cleaned" for r in holdout),
        "predictionFilesSHA256": {name: digest(args.output / name) for name in ("predictions.jsonl", "holdout.jsonl")},
        "adversarialMetricNote": "Existing adversarialSafe counts fallback only; safe accepted edits also fail this strict metric. Inspect raw outputs.",
        "peakMLXMemoryBytes": mx.get_peak_memory(),
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["fixtures"], sort_keys=True))


if __name__ == "__main__":
    main()
