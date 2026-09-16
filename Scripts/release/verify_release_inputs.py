#!/usr/bin/env python3
import argparse, hashlib, json, sys
from pathlib import Path

def digest(path):
    value=hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda:file.read(1024*1024),b""): value.update(chunk)
    return value.hexdigest()

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_release import summarize


def validate_measurements(measurements, report, expected_ids):
    summary = summarize(report.get("results", []), expected_ids)
    if report.get("hardware") != "8 GB Apple M1" or not summary["passed"]:
        raise ValueError("physical M1 benchmark did not pass")
    for key, value in summary.items():
        if report.get(key) != value:
            raise ValueError(f"benchmark summary mismatch: {key}")
    for config_key, report_key in (
        ("physicalM1P99Milliseconds", "p99Milliseconds"),
        ("physicalM1PeakFootprintBytes", "peakFootprintBytes"),
        ("physicalM1SteadyStateFootprintBytes", "steadyStateFootprintBytes"),
        ("cleanupTokenCeiling", "cleanupTokenCeiling"),
    ):
        if measurements.get(config_key) != summary[report_key]:
            raise ValueError(f"measurement mismatch: {config_key}")


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--config",type=Path,default=Path("Models/production-config.json"))
    parser.add_argument("--artifacts",type=Path,required=True)
    parser.add_argument("--quality-report",type=Path,required=True)
    parser.add_argument("--m1-report",type=Path,required=True)
    parser.add_argument("--fixtures",type=Path,default=Path(__file__).resolve().parents[2] / "Evals/fixtures/gold.jsonl")
    args=parser.parse_args()
    config=json.loads(args.config.read_text())
    if config.get("releaseStatus")!="release": sys.exit("production config is not marked release")
    measurements=config["releaseMeasurements"]
    for key in ("cleanupTokenCeiling","physicalM1P99Milliseconds","physicalM1PeakFootprintBytes","physicalM1SteadyStateFootprintBytes","qualityReportSHA256"):
        if measurements.get(key) is None: sys.exit(f"missing measured {key}")
    if not args.quality_report.is_file() or digest(args.quality_report)!=measurements["qualityReportSHA256"]: sys.exit("quality report hash mismatch")
    m1=json.loads(args.m1_report.read_text())
    if not m1.get("passed") or m1.get("hardware")!="8 GB Apple M1": sys.exit("physical M1 benchmark did not pass")
    validate_measurements(measurements, m1, [json.loads(line)["id"] for line in args.fixtures.read_text().splitlines() if line.strip()])
    for role in ("recognition","cleanup"):
        metadata=config[role]; artifact=args.artifacts/metadata["archivePath"]
        if not artifact.is_file(): sys.exit(f"missing {role} artifact")
        if artifact.stat().st_size!=metadata["byteSize"] or digest(artifact)!=metadata["sha256"]: sys.exit(f"{role} artifact evidence mismatch")
    print(json.dumps({"status":"passed","qualityReport":str(args.quality_report),"m1Report":str(args.m1_report)},sort_keys=True))

if __name__=="__main__": main()
