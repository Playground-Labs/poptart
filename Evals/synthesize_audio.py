#!/usr/bin/env python3
"""Render authored evaluation text using an installed macOS voice, for local smoke tests only."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import tempfile
import wave
from pathlib import Path

import run as evaluation

ROOT = Path(__file__).resolve().parents[1]


def validate(records):
    if not records or len({record['id'] for record in records}) != len(records):
        raise ValueError('empty or duplicate fixture IDs')
    for record in records:
        if (record.get('provenance') != evaluation.PROVENANCE
                or any(field in record for field in evaluation.FORBIDDEN_FIELDS)
                or not re.fullmatch(r'[A-Za-z0-9_-]+', record['id'])):
            raise ValueError('authored synthetic provenance and filename-safe IDs required')
        if '[[' in record['raw'] or ']]' in record['raw']:
            raise ValueError('speech markup is not supported')
        evaluation.validate_gold(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'Evals/fixtures/spoken.jsonl')
    parser.add_argument('--output', type=Path, default=ROOT / '.build/audio-smoke')
    parser.add_argument('--voice', default='Samantha')
    parser.add_argument('--rate', type=int, default=170)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or not 80 <= args.rate <= 300:
        parser.error('macOS and a speech rate of 80–300 words/minute are required')
    records = evaluation.load(args.fixtures)
    validate(records)
    sandbox = ['/usr/bin/sandbox-exec', '-f', str(ROOT / 'Scripts/privacy/deny-network.sb')]
    voices = subprocess.check_output(sandbox + ['/usr/bin/say', '-v', '?'], text=True)
    if not any(re.match(re.escape(args.voice) + r'\s+[a-z]{2}_', line) for line in voices.splitlines()):
        parser.error('voice must already be installed; no voice downloads are performed')
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output) as temporary:
        staging = Path(temporary)
        evidence = []
        for record in records:
            path = staging / (record['id'] + '.wav')
            subprocess.run(sandbox + ['/usr/bin/say', '-v', args.voice, '-r', str(args.rate),
                           '--file-format=WAVE', '--data-format=LEI16@16000', '--channels=1',
                           '-o', str(path), '-f', '-'], input=record['raw'], text=True, check=True, timeout=60)
            with wave.open(str(path)) as audio:
                if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                    raise ValueError('synthesizer did not produce mono 16 kHz PCM16')
                duration = audio.getnframes() / audio.getframerate()
                if not 0 < duration < 300:
                    raise ValueError('synthesized duration is outside runner bounds')
            evidence.append(dict(id=record['id'], durationSeconds=duration,
                                 rawSHA256=hashlib.sha256(record['raw'].encode()).hexdigest(),
                                 wavSHA256=hashlib.sha256(path.read_bytes()).hexdigest()))
        manifest = dict(schemaVersion=1, purpose='localSyntheticSmokeOnly', qualityClaim=False,
                        voice=args.voice, wordsPerMinute=args.rate, macOS=platform.mac_ver()[0],
                        osBuild=subprocess.check_output(['/usr/bin/sw_vers', '-buildVersion'], text=True).strip(),
                        fixturesSHA256=hashlib.sha256(args.fixtures.read_bytes()).hexdigest(), records=evidence)
        for record in records:
            name = record['id'] + '.wav'
            (staging / name).replace(args.output / name)
        (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(fixtures=len(records), output=str(args.output), qualityClaim=False)))


if __name__ == '__main__':
    main()
