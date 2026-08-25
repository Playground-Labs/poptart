#!/usr/bin/env python3
import argparse, json, platform, subprocess, sys
from pathlib import Path

def sysctl(name):
    return subprocess.run(["/usr/sbin/sysctl", "-n", name], check=True, capture_output=True, text=True).stdout.strip()

def main():
    parser = argparse.ArgumentParser(description="Run the exact physical-M1 release benchmark")
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64": sys.exit("physical Apple Silicon macOS required")
    if "Apple M1" not in sysctl("machdep.cpu.brand_string"): sys.exit("physical Apple M1 required")
    if int(sysctl("hw.memsize")) != 8 * 1024**3: sys.exit("exact 8 GB M1 baseline required")
    if int(platform.mac_ver()[0].split(".")[0]) < 15: sys.exit("macOS 15 or newer required")
    if not args.runner.is_file() or not args.runner.stat().st_mode & 0o111: sys.exit("executable production benchmark runner required")
    if not args.model.is_dir(): sys.exit("exact quantized model directory required")
    command = [str(args.runner), "--fixtures", "Evals/fixtures/gold.jsonl", "--model", str(args.model), "--jsonl"]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    rows = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    if not rows or any("elapsedMilliseconds" not in row or "id" not in row for row in rows): sys.exit("runner returned invalid benchmark records")
    elapsed = sorted(float(row["elapsedMilliseconds"]) for row in rows)
    p99 = elapsed[max(0, (99 * len(elapsed) + 99) // 100 - 1)]
    report = {"schemaVersion":1,"hardware":"8 GB Apple M1","sampleCount":len(rows),"p99Milliseconds":p99,"within1500Milliseconds":sum(v <= 1500 for v in elapsed),"passed":p99 <= 1500 and sum(v <= 1500 for v in elapsed) / len(elapsed) >= 0.99}
    args.output.write_text(json.dumps(report, sort_keys=True, separators=(",", ":")) + "\n")
    print(json.dumps(report, sort_keys=True))
    if not report["passed"]: sys.exit(1)

if __name__ == "__main__": main()
