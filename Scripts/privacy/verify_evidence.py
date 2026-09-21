#!/usr/bin/env python3
"""Validate privacy evidence; missing observations are failures, never zero traffic."""
import math
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_release import summarize


def deny_results(rows, fixture_ids):
    summary = summarize(rows, fixture_ids)
    # A fallback may prove delivery, but does not prove successful model Cleanup offline.
    if any(row["outcome"] != "cleaned" for row in rows):
        raise ValueError("normal recognition and model Cleanup were not proven for every fixture")
    return {"dictationProven": True, "dictationRows": summary["sampleCount"],
            "historyRecordsReadBack": len(rows), "settingsReadback": True}


def traffic_results(lines, stats, phases, installed):
    names = ("captureReady", "appStarted", "downloadStarted", "downloadFinished", "captureFinished")
    times = [phases.get(name) for name in names]
    if any(type(t) not in (int, float) or not math.isfinite(t) for t in times) or not all(a < b for a, b in zip(times, times[1:])):
        raise ValueError("missing or unordered capture phases")
    dropped = re.findall(r"(\d+) packets dropped by kernel", stats)
    captured = re.findall(r"(\d+) packets captured", stats)
    if not dropped or int(dropped[-1]) != 0 or not captured:
        raise ValueError("capture statistics missing or packets dropped")
    counts = {"before": 0, "during": 0, "after": 0}
    for line in lines:
        if not line.strip():
            continue
        match = re.match(r"^(\d+\.\d+)\s", line)
        if not match:
            raise ValueError("unparseable packet timestamp")
        timestamp = float(match[1])
        if timestamp < times[0] or timestamp > times[-1]:
            raise ValueError("packet outside capture lifetime")
        phase = "before" if timestamp < times[2] else "during" if timestamp <= times[3] else "after"
        counts[phase] += 1
    if sum(counts.values()) != int(captured[-1]):
        raise ValueError("packet count or process attribution mismatch")
    if not installed or not counts["during"]:
        raise ValueError("download and installation not observed")
    return {"schemaVersion": 1, "scope": "network-silence-outside-explicit-download",
            "destinationsVerified": False, "packetsBeforeDownload": counts["before"],
            "packetsDuringDownload": counts["during"], "packetsAfterDownload": counts["after"],
            "downloadObserved": True, "passed": counts["before"] == counts["after"] == 0}


if __name__ == "__main__":
    try:
        mode, *args = sys.argv[1:]
        if mode == "deny":
            rows = [json.loads(line) for line in Path(args[0]).read_text().splitlines() if line.strip()]
            ids = [json.loads(line)["id"] for line in Path(args[1]).read_text().splitlines() if line.strip()]
            print(json.dumps(deny_results(rows, ids), sort_keys=True))
        elif mode == "traffic":
            evidence = Path(args[0])
            report = traffic_results((evidence / "packets.txt").read_text().splitlines(),
                                     (evidence / "capture.log").read_text(),
                                     json.loads((evidence / "phases.json").read_text()),
                                     (evidence / "installed-model-pack.json").is_file())
            Path(args[1]).write_text(json.dumps(report, sort_keys=True) + "\n")
            print(json.dumps(report, sort_keys=True))
            sys.exit(0 if report["passed"] else 1)
        else:
            raise ValueError("expected deny or traffic")
    except (ValueError, OSError, IndexError, KeyError) as error:
        sys.exit(str(error))
