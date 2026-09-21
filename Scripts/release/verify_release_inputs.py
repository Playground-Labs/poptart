#!/usr/bin/env python3
import argparse, hashlib, json, subprocess, sys
from pathlib import Path

def digest(path):
    value=hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda:file.read(1024*1024),b""): value.update(chunk)
    return value.hexdigest()

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchmark_release import summarize, execution_identity as benchmark_identity
from model_files import model_inventory, summary, validate_cleanup_layout
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Evals"))
import run as evaluation
import baseline
from build_model_manifest import validate_manifest


def validate_quality(report, predictions_path, runner_path, cleanup_token_ceiling, require_pass=True):
    if type(cleanup_token_ceiling) is not int or cleanup_token_ceiling <= 0:
        raise ValueError("positive shipping Cleanup token ceiling required")
    predictions = evaluation.load(predictions_path)
    for row in predictions:
        if (type(row.get("maximumInputTokens")) is not int
                or row["maximumInputTokens"] != cleanup_token_ceiling
                or type(row.get("inputTokens")) is not int
                or not 0 < row["inputTokens"] <= cleanup_token_ceiling):
            raise ValueError("quality prediction token counts differ from the shipping Cleanup ceiling")
    directory = evaluation.RELEASE_DIRECTORY
    expected = evaluation.build_report(directory / "gold.jsonl", directory / "adversarial.jsonl",
                                       predictions_path, release=True)
    identity = report.get("executionIdentity")
    if not isinstance(identity, dict) or not isinstance(identity.get("modelFiles"), dict):
        raise ValueError("quality report lacks evaluated model identity; use the native evaluation wrapper")
    for name, value in baseline.runtime_identity(runner_path).items():
        if identity.get(name) != value:
            raise ValueError(f"quality runtime identity is missing or stale: {name}")
    if any(identity.get(name) != expected[name] for name in ("goldSHA256", "adversarialSHA256")):
        raise ValueError("evaluated fixture identity mismatch")
    expected["executionIdentity"] = identity
    evaluation.validate_native_probes(report.get("nativeProbes"), evaluation.load(directory / "adversarial.jsonl"))
    expected["nativeProbes"] = report["nativeProbes"]
    expected["measurements"] = baseline.resource_measurements(
        predictions, predictions_path.with_name("native-resources.txt").read_text())
    if report != expected:
        raise ValueError("quality report does not match frozen fixtures and prediction evidence")
    if require_pass and not expected["releaseGate"]["passed"]:
        raise ValueError("quality gate failed: " + ", ".join(expected["releaseGate"]["failures"]))


def compare_quality(current, previous):
    regressions = [name for name in evaluation.RELEASE_MINIMUM_RATES
                   if current[name]["applicable"] != previous[name]["applicable"]
                   or current[name]["passed"] < previous[name]["passed"]]
    if regressions:
        raise ValueError("quality regressed against shipped pack: " + ", ".join(regressions))


def validate_cleanup_files(identity, files):
    expected = identity["modelFiles"]
    validate_cleanup_layout(expected)
    if {name.removeprefix("cleanup/"): value["sha256"] for name, value in files.items()} != expected:
        raise ValueError("shipping Cleanup files differ from evaluated model")


def verified_artifact(metadata, directory, role):
    files = model_inventory(directory, role)
    if summary(files) != {key: metadata.get(key) for key in ("byteSize", "sha256")}:
        raise ValueError("release model inventory size/hash mismatch")
    return files


def validate_measurements(measurements, report, expected_ids):
    summary = summarize(report.get("results", []), expected_ids)
    hardware = report.get("hardware")
    if (not isinstance(hardware, dict) or not isinstance(hardware.get("chip"), str)
            or not hardware["chip"].startswith("Apple M") or hardware.get("architecture") != "arm64"
            or hardware.get("virtualized") is not False or type(hardware.get("memoryBytes")) is not int
            or hardware["memoryBytes"] <= 0 or not summary["passed"]):
        raise ValueError("physical Apple Silicon benchmark did not pass")
    for key, value in summary.items():
        if report.get(key) != value:
            raise ValueError(f"benchmark summary mismatch: {key}")
    for config_key, report_key in (
        ("benchmarkP99Milliseconds", "p99Milliseconds"),
        ("benchmarkPeakFootprintBytes", "peakFootprintBytes"),
        ("benchmarkSteadyStateFootprintBytes", "steadyStateFootprintBytes"),
        ("cleanupTokenCeiling", "cleanupTokenCeiling"),
    ):
        if measurements.get(config_key) != summary[report_key]:
            raise ValueError(f"measurement mismatch: {config_key}")
    if measurements.get("benchmarkHardware") != hardware or measurements.get("benchmarkMacOS") != report.get("macOS"):
        raise ValueError("benchmark platform differs from release metadata")


def validate_benchmark_evidence(report, runner, pack, audio, fixtures):
    if report.get("executionIdentity") != benchmark_identity(runner, pack, audio, fixtures):
        raise ValueError("benchmark identity differs from shipping models, runtime, manifest or audio")


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--config",type=Path,default=Path("Models/production-config.json"))
    parser.add_argument("--artifacts",type=Path,required=True)
    parser.add_argument("--quality-report",type=Path,required=True)
    parser.add_argument("--quality-predictions",type=Path,required=True)
    parser.add_argument("--quality-runner",type=Path,required=True,help="retained trusted native evaluator binary")
    predecessor=parser.add_mutually_exclusive_group(required=True)
    predecessor.add_argument("--initial-release",action="store_true",help="explicitly attest that no model pack has shipped")
    predecessor.add_argument("--previous-quality-report",type=Path)
    parser.add_argument("--previous-quality-predictions",type=Path)
    parser.add_argument("--previous-release-config",type=Path)
    parser.add_argument("--previous-artifacts",type=Path)
    parser.add_argument("--benchmark-report",type=Path,required=True)
    parser.add_argument("--benchmark-runner",type=Path,required=True,help="retained benchmark binary measured on the declared Mac")
    parser.add_argument("--audio",type=Path,required=True,help="exact measured audio fixtures")
    parser.add_argument("--fixtures",type=Path,default=Path(__file__).resolve().parents[2] / "Evals/fixtures/gold.jsonl")
    args=parser.parse_args()
    prior_inputs = [args.previous_quality_report, args.previous_quality_predictions, args.previous_release_config, args.previous_artifacts]
    if any(prior_inputs) and not all(prior_inputs):
        parser.error("previous report, predictions, retained shipped release config, and artifacts are required together")
    config=json.loads(args.config.read_text())
    if config.get("releaseStatus")!="release": sys.exit("production config is not marked release")
    if config.get("artifactHashFormat") != "sha256-canonical-file-inventory-v1":
        sys.exit("per-file model inventory hash format required")
    measurements=config["releaseMeasurements"]
    for key in ("cleanupTokenCeiling","benchmarkHardware","benchmarkMacOS","benchmarkP99Milliseconds","benchmarkPeakFootprintBytes","benchmarkSteadyStateFootprintBytes","qualityReportSHA256"):
        if measurements.get(key) is None: sys.exit(f"missing measured {key}")
    if not args.quality_report.is_file() or digest(args.quality_report)!=measurements["qualityReportSHA256"]: sys.exit("quality report hash mismatch")
    quality = json.loads(args.quality_report.read_text())
    validate_quality(quality, args.quality_predictions, args.quality_runner, measurements["cleanupTokenCeiling"])
    comparison = dict(mode="initial-release", predecessor=None)
    if args.previous_quality_report:
        previous=json.loads(args.previous_quality_report.read_text())
        shipped=json.loads(args.previous_release_config.read_text())
        if shipped.get("releaseStatus") != "release":
            raise ValueError("predecessor configuration is not a retained shipped release")
        validate_quality(previous, args.previous_quality_predictions, args.quality_runner,
                         shipped.get("releaseMeasurements", {}).get("cleanupTokenCeiling"), require_pass=False)
        previous_files=verified_artifact(shipped["cleanup"], args.previous_artifacts, "cleanup")
        validate_cleanup_files(previous["executionIdentity"], previous_files)
        compare_quality(quality, previous)
        comparison=dict(mode="shipped-pack", previousReportSHA256=digest(args.previous_quality_report),
                        previousReleaseConfigSHA256=digest(args.previous_release_config),
                        previousCleanupSHA256=shipped["cleanup"]["sha256"])
    benchmark=json.loads(args.benchmark_report.read_text())
    if not benchmark.get("passed"): sys.exit("physical Apple Silicon benchmark did not pass")
    validate_measurements(measurements, benchmark, [json.loads(line)["id"] for line in args.fixtures.read_text().splitlines() if line.strip()])
    validate_benchmark_evidence(benchmark, args.benchmark_runner, args.artifacts, args.audio, args.fixtures)
    validate_manifest(json.loads((args.artifacts / "manifest.json").read_text()), args.artifacts,
                      measurements["cleanupTokenCeiling"], config)
    for role in ("recognition","cleanup"):
        artifact=verified_artifact(config[role], args.artifacts, role)
        if role == "cleanup":
            validate_cleanup_files(quality["executionIdentity"], artifact)
    print(json.dumps({"status":"passed","qualityReport":str(args.quality_report),"benchmarkReport":str(args.benchmark_report),"comparison":comparison},sort_keys=True))

if __name__=="__main__": main()
