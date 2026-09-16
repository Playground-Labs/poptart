#!/usr/bin/env python3
"""Physical-M1 benchmark gate. Controlled delivery excludes live Accessibility insertion."""
import argparse
import json
import math
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sysctl(name):
    return subprocess.run(["/usr/sbin/sysctl", "-n", name], check=True, capture_output=True, text=True).stdout.strip()


def number(value, name, positive=False):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0 or (positive and value == 0):
        raise ValueError(f"invalid {name}")
    return value


def summarize(rows, expected_ids):
    ids = [row.get("id") for row in rows]
    if not expected_ids or len(set(expected_ids)) != len(expected_ids) or len(ids) != len(expected_ids) or set(ids) != set(expected_ids):
        raise ValueError("missing, duplicate, or unexpected fixture results")
    history_ids = set()
    for row in rows:
        for name in ("elapsedMilliseconds", "finalRecognitionMilliseconds", "cleanupMilliseconds", "deliveryMilliseconds"):
            number(row.get(name), name)
        for name in ("footprintBytes", "peakFootprintBytes", "mlxActiveBytes", "cleanupTokenCeiling"):
            number(row.get(name), name, positive=True)
            if type(row[name]) is not int:
                raise ValueError(f"non-integer {name}")
        if row["peakFootprintBytes"] < row["footprintBytes"]:
            raise ValueError("peak footprint is below current footprint")
        if row.get("bothModelsResident") is not True or row.get("historyReadback") is not True or row.get("settingsReadback") is not True:
            raise ValueError("missing residency or persistence evidence")
        if row.get("deliveryMode") != "controlled" or row.get("outcome") not in ("cleaned", "rawTranscript", "oversized", "recognitionHypothesis"):
            raise ValueError("invalid delivery outcome")
        if not isinstance(row.get("deliveredText"), str) or not row["deliveredText"].strip():
            raise ValueError("empty delivered text")
        record_id = row.get("historyRecordID")
        if not isinstance(record_id, str) or not record_id or record_id in history_ids:
            raise ValueError("missing or reused history record")
        history_ids.add(record_id)
    ceilings = {row["cleanupTokenCeiling"] for row in rows}
    if len(ceilings) != 1:
        raise ValueError("mixed Cleanup token ceilings")
    elapsed = sorted(row["elapsedMilliseconds"] for row in rows)
    p99 = elapsed[(99 * len(elapsed) + 99) // 100 - 1]
    within = sum(value <= 1500 for value in elapsed)
    return {"schemaVersion": 1, "sampleCount": len(rows), "p99Milliseconds": p99,
            "within1500Milliseconds": within, "passed": p99 <= 1500 and within / len(rows) >= .99,
            "steadyStateFootprintBytes": max(row["footprintBytes"] for row in rows),
            "peakFootprintBytes": max(row["peakFootprintBytes"] for row in rows),
            "mlxActiveBytes": max(row["mlxActiveBytes"] for row in rows),
            "bothModelsResident": True, "deliveryMode": "controlled",
            "cleanupTokenCeiling": next(iter(ceilings))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "Evals/fixtures/gold.jsonl")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps({"passed": False, "status": "incomplete"}) + "\n")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("physical Apple Silicon macOS required")
    if sysctl("machdep.cpu.brand_string") != "Apple M1" or sysctl("kern.hv_vmm_present") != "0":
        sys.exit("physical Apple M1 required")
    if int(sysctl("hw.memsize")) != 8 * 1024**3:
        sys.exit("exact 8 GB M1 baseline required")
    if int(platform.mac_ver()[0].split(".")[0]) < 15:
        sys.exit("macOS 15 or newer required")
    if not args.runner.is_file() or not args.runner.stat().st_mode & 0o111:
        sys.exit("executable production benchmark runner required")
    if not args.model.is_dir() or not args.audio.is_dir():
        sys.exit("local model and audio directories required")
    completed = subprocess.run([str(args.runner.resolve()), "--fixtures", str(args.fixtures.resolve()),
                                "--model", str(args.model.resolve()), "--audio", str(args.audio.resolve()), "--jsonl"],
                               check=True, capture_output=True, text=True)
    rows = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    fixtures = [json.loads(line)["id"] for line in args.fixtures.read_text().splitlines() if line.strip()]
    report = summarize(rows, fixtures)
    report.update(hardware="8 GB Apple M1", macOS=platform.mac_ver()[0], results=rows)
    args.output.write_text(json.dumps(report, sort_keys=True, allow_nan=False) + "\n")
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    if not report["passed"]:
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
