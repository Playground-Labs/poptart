#!/usr/bin/env python3
"""Run the native Cleanup engine and retain reproducible development evaluation evidence."""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import signal
import subprocess
import sys
from pathlib import Path

import run as evaluation

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Scripts'))
from model_files import inventory


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def runtime_identity(runner):
    paths = [ROOT / name for name in ('Package.resolved', 'Evals/baseline.py', 'Evals/run.py', 'Evals/editplan.py', 'Scripts/model_files.py')]
    for directory in ('Tools/CleanupEval', 'Packages/Cleanup/Sources', 'Packages/DictationCore/Sources'):
        paths.extend(sorted((ROOT / directory).rglob('*.swift')))
    return dict(runnerSHA256=digest(runner),
                systemPromptSourceSHA256=digest(ROOT / 'Packages/Cleanup/Sources/Cleanup/CleanupPrompt.swift'),
                sourceSHA256={str(path.relative_to(ROOT)): digest(path) for path in paths})


def execution_identity(runner, model, gold, adversarial):
    return dict(**runtime_identity(runner), goldSHA256=digest(gold), adversarialSHA256=digest(adversarial),
                modelFiles={name: value['sha256'] for name, value in inventory(model).items()})


def resource_measurements(rows, usage):
    """Cleanup-only timings and native process high-water marks, never delivery latency."""
    elapsed = [row['elapsedMilliseconds'] for row in rows]
    if not elapsed or any(isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) or n < 0 for n in elapsed):
        raise ValueError('finite non-negative Cleanup timings required')
    elapsed.sort()
    memory = {}
    for key, label in [('peakFootprintBytes', 'peak memory footprint'),
                       ('maximumResidentSetBytes', 'maximum resident set size')]:
        values = re.findall(r'^\s*([0-9]+)\s+' + label + r'\s*$', usage, re.MULTILINE)
        if len(values) > 1:
            raise ValueError('duplicate native memory measurement')
        memory[key] = int(values[0]) if values and int(values[0]) > 0 else None
    for field, key in [('mlxActiveBytes', 'maximumObservedMLXActiveBytes'),
                       ('mlxCacheBytes', 'maximumObservedMLXCacheBytes'),
                       ('mlxPeakActiveBytes', 'peakMLXActiveBytes')]:
        values = [row.get(field) for row in rows]
        if all(value is None for value in values):
            memory[key] = None
        elif any(type(value) is not int or value < 0 for value in values):
            raise ValueError('complete non-negative integer MLX measurements required')
        else:
            memory[key] = max(values)
    residency = [row.get('modelResident') for row in rows]
    if all(value is None for value in residency):
        memory['modelResidentInAllObservations'] = None
    elif any(type(value) is not bool for value in residency):
        raise ValueError('complete boolean model residency measurements required')
    else:
        memory['modelResidentInAllObservations'] = all(residency)
    return dict(scope='Cleanup-only process; excludes recognition and application insertion',
                timing='prepared model; prompt preparation, generation and validation; first request includes kernel warmup',
                cases=len(elapsed), latencyMilliseconds={
                    'p50': elapsed[math.ceil(len(elapsed) * .50) - 1],
                    'p95': elapsed[math.ceil(len(elapsed) * .95) - 1],
                    'p99': elapsed[math.ceil(len(elapsed) * .99) - 1],
                    'maximum': elapsed[-1]}, **memory)


def run_native(command, timeout):
    # time(1) has a child: kill and reap the whole group on timeout or interruption.
    process = subprocess.Popen(command, env={**os.environ, 'LC_ALL': 'C'}, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    if status:
        raise subprocess.CalledProcessError(status, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    parser.add_argument('--gold', type=Path)
    parser.add_argument('--release-suite', action='store_true')
    parser.add_argument('--challenger', choices=['gemma3'])
    parser.add_argument('--max-input-tokens', type=int, default=2048)
    args = parser.parse_args()
    if args.gold and args.release_suite:
        parser.error('--gold cannot override the frozen release suite')
    directory = evaluation.RELEASE_DIRECTORY if args.release_suite else ROOT / 'Evals/fixtures'
    args.gold = args.gold or directory / 'gold.jsonl'
    adversarial_path = directory / 'adversarial.jsonl'
    evaluation.build_report(args.gold, adversarial_path, release=args.release_suite)
    gold, adversarial = evaluation.load(args.gold), evaluation.load(adversarial_path)
    evaluation.validate_fixtures(gold, adversarial)
    if args.max_input_tokens < 1 or not args.model.is_dir() or not args.runner.is_file():
        parser.error('existing local model/runner and positive token ceiling required')
    args.output_directory.mkdir(parents=True, exist_ok=False)
    output = args.output_directory / 'predictions.jsonl'
    command = [str(args.runner.resolve()), '--model', str(args.model.resolve()), '--gold', str(args.gold.resolve()),
               '--adversarial', str(adversarial_path), '--output', str(output.resolve()),
               '--max-input-tokens', str(args.max_input_tokens)]
    if args.challenger:
        command.extend(['--challenger', args.challenger])
    identity = execution_identity(args.runner, args.model, args.gold, adversarial_path)
    probes_path = args.output_directory / 'native-probes.jsonl'
    subprocess.run([str(args.runner.resolve()), '--probes-only', '--adversarial', str(adversarial_path),
                    '--output', str(probes_path.resolve())], check=True, timeout=60)
    probes = evaluation.load(probes_path)
    evaluation.validate_native_probes(probes, adversarial)
    usage_path = args.output_directory / 'native-resources.txt'
    measured_command = ['/usr/bin/time', '-l', '-o', str(usage_path.resolve()), *command]
    run_native(measured_command, timeout=60 + 65 * (len(gold) + len(adversarial)))
    if execution_identity(args.runner, args.model, args.gold, adversarial_path) != identity:
        raise ValueError('runner, model, fixtures, or source changed during evaluation; discard this run')
    rows = evaluation.load(output)
    predictions = evaluation.prediction_map(gold, adversarial, rows)
    failures = []
    for record in gold:
        row = predictions[record['id']]
        failed = [name for name, measure in evaluation.DIMENSIONS
                  if (name != 'vocabularyPreservation' or evaluation.applicable_vocabulary_terms(record))
                  and not measure(record, row)]
        if failed:
            failures.append(dict(id=record['id'], dimensions=failed, expected=record['expected'],
                                 actual=row['output'], outcome=row['outcome']))
    for record in adversarial:
        if not evaluation.adversarial_safe(record, predictions[record['id']]):
            failures.append(dict(id=record['id'], dimensions=['adversarialSafe'],
                                 actual=predictions[record['id']]['output']))
    for record in gold + adversarial:
        if not evaluation.runtime_consistent(record, predictions[record['id']]):
            failures.append(dict(id=record['id'], dimensions=['runtimeConsistency']))
    report = evaluation.build_report(args.gold, adversarial_path, output, args.release_suite)
    report['executionIdentity'] = identity
    if args.challenger:
        report['evaluationMode'] = args.challenger
    report['nativeProbes'] = probes
    report['measurements'] = resource_measurements(rows, usage_path.read_text())
    evidence = dict(command=command, hardware=subprocess.check_output(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                    macOS=platform.mac_ver()[0], maximumInputTokens=args.max_input_tokens,
                    **identity, predictionsSHA256=digest(output),
                    swiftPins=json.loads((ROOT / 'Package.resolved').read_text()),
                    measuredCommand=measured_command, nativeResourcesSHA256=digest(usage_path),
                    )
    for name, value in [('report', report), ('evidence', evidence), ('failures', failures)]:
        (args.output_directory / (name + '.json')).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
