#!/usr/bin/env python3
"""Offline release-gate regressions; all artifacts and reports are synthetic."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseInputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.quality = self.root / "quality.json"
        self.quality.write_text('{"syntheticTestOnly":true}\n')
        self.config = {
            "releaseStatus": "release",
            "releaseMeasurements": {
                "cleanupTokenCeiling": 512,
                "physicalM1P99Milliseconds": 1200,
                "qualityReportSHA256": hashlib.sha256(self.quality.read_bytes()).hexdigest(),
            },
        }
        for role in ("recognition", "cleanup"):
            artifact = self.root / role
            artifact.write_bytes(b"x")
            self.config[role] = {
                "archivePath": role, "byteSize": 1,
                "sha256": hashlib.sha256(b"x").hexdigest(),
            }
        self.m1 = {
            "hardware": "8 GB Apple M1", "passed": True,
            "p99Milliseconds": 1200, "sampleCount": 100,
            "within1500Milliseconds": 99,
        }

    def run_gate(self):
        config = self.root / "config.json"
        report = self.root / "m1.json"
        config.write_text(json.dumps(self.config))
        report.write_text(json.dumps(self.m1))
        return subprocess.run([
            sys.executable, str(ROOT / "Scripts/release/verify_release_inputs.py"),
            "--config", str(config), "--artifacts", str(self.root),
            "--quality-report", str(self.quality), "--m1-report", str(report),
        ], capture_output=True, text=True)

    def test_consistent_evidence_passes(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unreleased_and_changed_evidence_rejected(self):
        self.config["releaseStatus"] = "unreleased"
        self.assertNotEqual(self.run_gate().returncode, 0)
        self.config["releaseStatus"] = "release"
        self.quality.write_text("changed")
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_invalid_measurements_rejected(self):
        original = copy.deepcopy(self.config)
        for key, value in [
            ("cleanupTokenCeiling", True), ("cleanupTokenCeiling", 0),
            ("cleanupTokenCeiling", 1.5),
            ("physicalM1P99Milliseconds", float("nan")),
            ("physicalM1P99Milliseconds", -1),
            ("physicalM1P99Milliseconds", 1201),
        ]:
            with self.subTest(key=key, value=value):
                self.config = copy.deepcopy(original)
                self.config["releaseMeasurements"][key] = value
                self.assertNotEqual(self.run_gate().returncode, 0)

    def test_pass_flag_cannot_override_failed_measurements(self):
        original = self.m1.copy()
        for key, value in [
            ("passed", "false"), ("passed", 1),
            ("p99Milliseconds", 1501), ("p99Milliseconds", float("nan")),
            ("p99Milliseconds", True), ("p99Milliseconds", -1),
            ("sampleCount", 0), ("sampleCount", True),
            ("within1500Milliseconds", 98), ("within1500Milliseconds", 101),
            ("within1500Milliseconds", True),
        ]:
            with self.subTest(key=key, value=value):
                self.m1 = original | {key: value}
                self.assertNotEqual(self.run_gate().returncode, 0)

    def test_boolean_artifact_size_rejected(self):
        self.config["cleanup"]["byteSize"] = True
        self.assertNotEqual(self.run_gate().returncode, 0)


class SigningPreflightTests(unittest.TestCase):
    def test_signing_preflight_accepts_valid_and_rejects_invalid_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "key"
            key.write_text("not a real key")
            openssl = root / "openssl"
            openssl.write_text('#!/bin/sh\necho "SIGNING_WAS_ATTEMPTED" >&2\nexit 99\n')
            openssl.chmod(0o755)
            artifact = {"role": "recognition", "byteSize": 1, "sha256": "a" * 64}
            cleanup = artifact | {"role": "cleanup"}
            for artifacts, valid in (
                ([artifact, cleanup], True),
                ([artifact, cleanup, cleanup], False),
                ([artifact, cleanup | {"byteSize": True}], False),
            ):
                with self.subTest(artifacts=artifacts):
                    manifest = root / "manifest.json"
                    manifest.write_text(json.dumps({"cleanupTokenCeiling": 512, "artifacts": artifacts}))
                    result = subprocess.run([
                        "sh", str(ROOT / "Scripts/release/sign_model_pack.sh"),
                        str(manifest), str(key), str(root / "output.json"),
                    ], env=os.environ | {"PATH": str(root) + os.pathsep + os.environ["PATH"]},
                        capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    if valid:
                        self.assertEqual(result.returncode, 99)
                        self.assertIn("SIGNING_WAS_ATTEMPTED", result.stderr)
                    else:
                        self.assertNotIn("SIGNING_WAS_ATTEMPTED", result.stderr)
                    self.assertFalse((root / "output.json").exists())


if __name__ == "__main__":
    unittest.main()
