#!/usr/bin/env python3
import argparse, hashlib, json, math, sys
from pathlib import Path

def digest(path):
    value=hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda:file.read(1024*1024),b""): value.update(chunk)
    return value.hexdigest()

def valid_milliseconds(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1500

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--config",type=Path,default=Path("Models/production-config.json"))
    parser.add_argument("--artifacts",type=Path,required=True)
    parser.add_argument("--quality-report",type=Path,required=True)
    parser.add_argument("--m1-report",type=Path,required=True)
    args=parser.parse_args()
    config=json.loads(args.config.read_text())
    if config.get("releaseStatus")!="release": sys.exit("production config is not marked release")
    measurements=config["releaseMeasurements"]
    for key in ("cleanupTokenCeiling","physicalM1P99Milliseconds","qualityReportSHA256"):
        if measurements.get(key) is None: sys.exit(f"missing measured {key}")
    ceiling=measurements["cleanupTokenCeiling"]
    if type(ceiling) is not int or ceiling <= 0: sys.exit("cleanup token ceiling must be a positive integer")
    if not valid_milliseconds(measurements["physicalM1P99Milliseconds"]): sys.exit("invalid configured M1 p99")
    if not args.quality_report.is_file() or digest(args.quality_report)!=measurements["qualityReportSHA256"]: sys.exit("quality report hash mismatch")
    m1=json.loads(args.m1_report.read_text())
    if m1.get("passed") is not True or m1.get("hardware")!="8 GB Apple M1": sys.exit("physical M1 benchmark did not pass")
    p99=m1.get("p99Milliseconds")
    count=m1.get("sampleCount")
    within=m1.get("within1500Milliseconds")
    if not valid_milliseconds(p99) or p99!=measurements["physicalM1P99Milliseconds"]: sys.exit("M1 p99 evidence mismatch")
    if type(count) is not int or count <= 0 or type(within) is not int or not 0 <= within <= count: sys.exit("invalid M1 sample counts")
    if within * 100 < count * 99: sys.exit("physical M1 benchmark missed the 99 percent deadline gate")
    for role in ("recognition","cleanup"):
        metadata=config[role]; artifact=args.artifacts/metadata["archivePath"]
        if type(metadata.get("byteSize")) is not int or metadata["byteSize"] <= 0: sys.exit(f"invalid {role} artifact byte size")
        if not artifact.is_file(): sys.exit(f"missing {role} artifact")
        if artifact.stat().st_size!=metadata["byteSize"] or digest(artifact)!=metadata["sha256"]: sys.exit(f"{role} artifact evidence mismatch")
    print(json.dumps({"status":"passed","qualityReport":str(args.quality_report),"m1Report":str(args.m1_report)},sort_keys=True))

if __name__=="__main__": main()
