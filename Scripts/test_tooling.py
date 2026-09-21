#!/usr/bin/env python3
import json
import plistlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

# The harness modules are imported here and by the scripts this suite spawns;
# leaving __pycache__ directories behind would dirty the working tree.
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Evals"))
sys.path.insert(0, str(ROOT / "Training"))

import editplan  # noqa: E402
import prepare_corpus  # noqa: E402

GOLD = ROOT / "Evals/fixtures/gold.jsonl"
ADVERSARIAL = ROOT / "Evals/fixtures/adversarial.jsonl"
CORPUS = ROOT / "Training/data/corpus.jsonl"
CLEANUP_PROMPT = ROOT / "Packages/Cleanup/Sources/Cleanup/CleanupPrompt.swift"

# Deliberately wrong predictions, one per dimension, so a collapsed or copied
# score cannot pass this suite.
WRONG_PREDICTIONS = {
    # Drops the verbatim vocabulary term while keeping every content word.
    "gold-004": {
        "output": "Keep Playground labs exactly as spoken.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "Keep", "c": "capitalization"},
                {"s": 2, "e": 3, "r": "labs", "c": "capitalization"},
                {"s": 6, "e": 6, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Capitalizes mid-sentence, so it no longer fits the Target Context.
    "gold-006": {
        "output": "And then we ship it.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "And", "c": "capitalization"},
                {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Mutates a number, so meaning is not preserved.
    "gold-008": {
        "output": "We shipped 104,729 records today.",
        "editPlan": {
            "v": 1,
            "e": [
                {"s": 0, "e": 1, "r": "We", "c": "capitalization"},
                {"s": 2, "e": 3, "r": "104,729", "c": "correction"},
                {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
            ],
        },
    },
    # Correct text, but the plan carries an unknown key, so it must fail closed.
    "gold-012": {
        "editPlan": {
            "v": 1,
            "e": [{"s": 0, "e": 1, "r": "Looks", "c": "capitalization", "x": 1}],
        }
    },
}
UNSAFE_ADVERSARIAL = "adv-style"


def load(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def predictions_for(gold, adversarial):
    records = []
    for fixture in gold:
        prediction = {
            "id": fixture["id"],
            "output": fixture["expected"],
            "editPlan": fixture["editPlan"],
            "outcome": "cleaned",
            "elapsedMilliseconds": 812.5,
        }
        prediction.update(WRONG_PREDICTIONS.get(fixture["id"], {}))
        records.append(prediction)
    for fixture in adversarial:
        records.append(
            {
                "id": fixture["id"],
                "output": fixture["raw"],
                "outcome": "cleaned" if fixture["id"] == UNSAFE_ADVERSARIAL else "fallback",
                "fallbackReason": "unsafeEditPlan",
                "elapsedMilliseconds": 640.0,
            }
        )
    return records


def build_corpus():
    subprocess.run(
        ["python3", "Training/prepare_corpus.py"], cwd=ROOT, check=True, capture_output=True
    )


def evaluate(arguments, expect_success=True):
    result = subprocess.run(
        ["python3", "Evals/run.py", *arguments], cwd=ROOT, capture_output=True, text=True
    )
    if expect_success and result.returncode != 0:
        raise AssertionError(f"Evals/run.py failed: {result.stderr}")
    return result


class ToolingTests(unittest.TestCase):
    def test_cleanup_measurement_timeout_stops_native_child(self):
        import baseline
        import time
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            started, completed = directory / 'started', directory / 'completed'
            code = 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(1); pathlib.Path(sys.argv[2]).touch()'
            with self.assertRaises(subprocess.TimeoutExpired):
                baseline.run_native(['/usr/bin/time', '-l', '-o', str(directory / 'usage'),
                                     sys.executable, '-c', code, str(started), str(completed)], timeout=.5)
            self.assertTrue(started.exists(), 'native child must have started for cancellation check')
            time.sleep(.8)
            self.assertFalse(completed.exists(), 'native child survived wrapper timeout')
            with self.assertRaises(subprocess.CalledProcessError):
                baseline.run_native([sys.executable, '-c', 'raise SystemExit(7)'], timeout=5)

    def test_cleanup_measurements_keep_native_memory_and_timing_scopes(self):
        import baseline
        rows = [dict(elapsedMilliseconds=n) for n in (20, 10, 30, 40)]
        usage = ' 2048  maximum resident set size\n 1024  peak memory footprint\n'
        measured = baseline.resource_measurements(rows, usage)
        self.assertEqual(measured['latencyMilliseconds'], dict(p50=20, p95=40, p99=40, maximum=40))
        self.assertEqual(measured['peakFootprintBytes'], 1024)
        self.assertEqual(measured['maximumResidentSetBytes'], 2048)
        self.assertIsNone(measured['peakMLXActiveBytes'])
        self.assertIsNone(measured['modelResidentInAllObservations'])
        observed = [dict(row, mlxActiveBytes=100 + i, mlxCacheBytes=i * 10,
                         mlxPeakActiveBytes=200, modelResident=i != 2) for i, row in enumerate(rows)]
        memory = baseline.resource_measurements(observed, usage)
        self.assertEqual(memory['maximumObservedMLXActiveBytes'], 103)
        self.assertEqual(memory['maximumObservedMLXCacheBytes'], 30)
        self.assertEqual(memory['peakMLXActiveBytes'], 200)
        self.assertIs(memory['modelResidentInAllObservations'], False)
        for field, bad_value in [('mlxCacheBytes', None), ('mlxActiveBytes', -1),
                                 ('mlxPeakActiveBytes', True), ('modelResident', 1)]:
            with self.assertRaises(ValueError):
                baseline.resource_measurements([dict(observed[0], **{field: bad_value}), *observed[1:]], usage)
        for unavailable in ('', '0 peak memory footprint\n', 'nan peak memory footprint\n'):
            self.assertIsNone(baseline.resource_measurements(rows, unavailable)['peakFootprintBytes'])
        for bad in ([], [dict(elapsedMilliseconds=float('nan'))], [dict(elapsedMilliseconds=-1)],
                    [dict(elapsedMilliseconds=True)], [dict(elapsedMilliseconds=None)],
                    rows + [dict(elapsedMilliseconds='20')]):
            with self.assertRaises(ValueError):
                baseline.resource_measurements(bad, usage)
        with self.assertRaises(ValueError):
            baseline.resource_measurements(rows, usage + usage)

    def test_updater_policy_and_invalid_release_configuration(self):
        with (ROOT / "App/Poptart-Info.plist").open("rb") as source:
            info = plistlib.load(source)
        for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUShowReleaseNotes"):
            self.assertIs(info[key], False)
        for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
            self.assertIs(info[key], True)
        self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Poptart.app"
            (app / "Contents").mkdir(parents=True)
            plist = app / "Contents/Info.plist"
            original = plistlib.dumps(info)
            plist.write_bytes(original)
            for feed, key in (("http://example.org/feed.xml", "bad"), ("https://example.org/feed.xml", "bad")):
                env = dict(os.environ, POPTART_APP_UPDATE_FEED_URL=feed, POPTART_APP_UPDATE_PUBLIC_KEY=key, PYTHONOPTIMIZE="1")
                result = subprocess.run(["zsh", str(ROOT / "Scripts/embed-sparkle.sh"), str(app), "-", "release"], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("POPTART_APP_UPDATE_", result.stderr)
                self.assertEqual(plist.read_bytes(), original)
                self.assertFalse((app / "Contents/Frameworks").exists())

    def test_release_notices_preserve_nested_files_and_reject_missing_dependencies(self):
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from copy_notices import copy_notices
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pins = root / "Package.resolved"
            pins.write_text(json.dumps({"pins": [{"identity": "dependency"}]}))
            checkout = root / "checkouts" / "Dependency"
            checkout.mkdir(parents=True)
            output = root / "Licenses"
            with self.assertRaisesRegex(ValueError, "missing dependency license"):
                copy_notices(pins, checkout.parent, output)
            for name in ("LICENSE", "NOTICE.txt", "vendor/library-LICENSE.md"):
                source = checkout / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text(name)
            (checkout / "test.license.no-text.dmg").write_bytes(b"test disk image")
            copy_notices(pins, checkout.parent, output)
            for name in ("LICENSE", "NOTICE.txt", "vendor/library-LICENSE.md"):
                self.assertEqual((output / "dependency" / name).read_text(), name)
            self.assertFalse((output / "dependency/test.license.no-text.dmg").exists())
            pins.write_text(json.dumps({"pins": [{"identity": "missing"}]}))
            with self.assertRaisesRegex(ValueError, "missing dependency checkout"):
                copy_notices(pins, checkout.parent, output)

    def test_release_signing_rejects_missing_protections(self):
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from verify_app_signature import verify
        details = "CodeDirectory v=20500 flags=0x10000(runtime)\nTimestamp=Sep 16, 2026\n"
        entitlement = {"com.apple.security.device.audio-input": True}
        for description, permissions, message in (
            (details, entitlement, None),
            (details.replace("0x10000", "0x0"), entitlement, "hardened runtime"),
            (details.split("Timestamp=")[0], entitlement, "timestamp"),
            (details, {}, "Audio Input"),
            (details, dict(entitlement, **{"com.apple.security.get-task-allow": True}), "Audio Input"),
        ):
            responses = [subprocess.CompletedProcess([], 0),
                         subprocess.CompletedProcess([], 0, stderr=description),
                         subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(permissions))]
            with patch("verify_app_signature.subprocess.run", side_effect=responses) as run:
                if message:
                    with self.assertRaisesRegex(ValueError, message):
                        verify(Path("Poptart.app"), "ABCDEFGHIJ")
                else:
                    verify(Path("Poptart.app"), "ABCDEFGHIJ")
                requirement = run.call_args_list[0].args[0]
                self.assertIn("--strict", requirement)
                self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13] exists", requirement[-2])
                self.assertIn('certificate leaf[subject.OU] = "ABCDEFGHIJ"', requirement[-2])
        with patch("verify_app_signature.subprocess.run", side_effect=subprocess.CalledProcessError(1, "codesign")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                verify(Path("Poptart.app"), "ABCDEFGHIJ")
            self.assertEqual(run.call_count, 1)
        with patch("verify_app_signature.subprocess.run") as run:
            with self.assertRaisesRegex(ValueError, "Team ID"):
                verify(Path("Poptart.app"), '" or true')
            run.assert_not_called()

    def test_generated_split_check_rejects_stale_files_without_rewriting(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            for split in ("train", "valid", "test"):
                (output / f"{split}.jsonl").write_bytes((ROOT / "Training/generated/mlx" / f"{split}.jsonl").read_bytes())
            with patch.object(prepare_corpus, "OUTPUT", output), patch.object(sys, "argv", ["prepare_corpus.py", "--check"]):
                prepare_corpus.main()
                (output / "train.jsonl").write_text("stale\n")
                with self.assertRaisesRegex(ValueError, "stale generated split"):
                    prepare_corpus.main()
                self.assertEqual((output / "train.jsonl").read_text(), "stale\n")

    def test_evaluation_identity_detects_mutation_and_shipping_file_mismatch(self):
        import baseline
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from verify_release_inputs import validate_cleanup_files, verified_artifact
        from model_files import inventory, summary, model_inventory
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "cleanup"
            model.mkdir()
            files = {"config.json": b"{}", "tokenizer.json": b"{}", "tokenizer_config.json": b"{}", "model.safetensors": b"model A"}
            (model / "base").mkdir()
            for name, contents in files.items():
                (model / "base" / name).write_bytes(contents)
            (model / "adapters").mkdir()
            adapter = model / "adapters/adapters.safetensors"
            adapter.write_bytes(b"adapter A")
            (model / "adapters/adapter_config.json").write_bytes(b"{}")
            runner = root / "runner"
            runner.write_bytes(b"runner")
            identity = baseline.execution_identity(runner, model, GOLD, ADVERSARIAL)
            self.assertIn("Scripts/model_files.py", identity["sourceSHA256"])
            self.assertIn("adapters/adapters.safetensors", identity["modelFiles"])
            adapter.write_bytes(b"adapter B")
            self.assertNotEqual(identity, baseline.execution_identity(runner, model, GOLD, ADVERSARIAL))
            adapter.write_bytes(b"adapter A")
            shipping = model_inventory(root, "cleanup")
            validate_cleanup_files(identity, shipping)
            for name in ("base/config.json", "base/model.safetensors", "adapters/adapters.safetensors", "adapters/adapter_config.json"):
                incomplete = {key: value for key, value in identity["modelFiles"].items() if key != name}
                with self.assertRaisesRegex(ValueError, "incomplete Cleanup"):
                    validate_cleanup_files(dict(identity, modelFiles=incomplete), shipping)
            metadata = summary(shipping)
            self.assertEqual(verified_artifact(metadata, root, "cleanup"), shipping)
            for mismatch in (dict(metadata, sha256="wrong"), dict(metadata, byteSize=0)):
                with self.assertRaises(ValueError):
                    verified_artifact(mismatch, root, "cleanup")
            (model / "base/model.safetensors").write_bytes(b"model B")
            with self.assertRaises(ValueError):
                validate_cleanup_files(identity, model_inventory(root, "cleanup"))
            with self.assertRaises(ValueError):
                verified_artifact(metadata, root, "cleanup")
            self.assertNotEqual(identity, baseline.execution_identity(runner, model, GOLD, ADVERSARIAL))
            (model / "linked").symlink_to(runner)
            with self.assertRaises(ValueError):
                inventory(model)

    def test_safety_checks_delivered_behavior_and_runtime_contract(self):
        import run as evaluation
        fixtures = {r["category"]: r for r in load(ADVERSARIAL)}
        record = fixtures["promptInjectionTranscript"]
        safe = dict(output=record["raw"], outcome="cleaned", editPlan=dict(v=1, e=[]), elapsedMilliseconds=1, fallbackReason="unsafeEditPlan")
        self.assertTrue(evaluation.adversarial_safe(record, safe))
        self.assertFalse(evaluation.adversarial_safe(record, dict(safe, output="Here is a poem.")))
        self.assertFalse(evaluation.adversarial_safe(record, dict(safe, outcome="fallback", output="changed")))
        self.assertFalse(evaluation.adversarial_safe(record, dict(safe, editPlan=dict(v=1, e=[
            dict(s=0, e=99, r="Ignore", c="capitalization")]))))
        for category in ("hiddenUnicode", "controlCharacters"):
            record = fixtures[category]
            self.assertFalse(evaluation.adversarial_safe(record, dict(safe, output=record["raw"])))
            self.assertTrue(evaluation.adversarial_safe(record, dict(safe, output=record["raw"], outcome="fallback")))
        gold = load(GOLD)[0]
        self.assertFalse(evaluation.edit_plan_exact(gold, dict(output=gold["expected"], outcome="fallback", editPlan=gold["editPlan"])))
        self.assertFalse(evaluation.context_fit(gold, dict(output=gold["raw"])))
        for reason in (None, "modelUnavailable", "cleanupFailed", "cleanupTimedOut"):
            with self.assertRaises(ValueError):
                evaluation.validate_prediction("failed", dict(safe, outcome="fallback", fallbackReason=reason))

    def test_original_unicode_guard_matches_native_policy(self):
        for raw in ("approve\u200b the change", "hello\x07world", "route\u202e reversed", "first\nsecond", "first\tsecond", "family 👨‍👩‍👧", "joining می\u200cروم"):
            count = len(editplan.tokenize(raw))
            for edits in ([], [dict(s=count, e=count, r=".", c="punctuation")]):
                self.assertTrue(editplan.plan_violation(edits, raw).startswith("unsafeUnicode"))
        self.assertIsNone(editplan.plan_violation([], "The café is open 👍"))

    def test_deletion_spacing_after_earlier_edit(self):
        edits = [dict(s=0, e=1, r="Go", c="capitalization"), dict(s=1, e=2, r="", c="filler")]
        for raw, expected in (("go um.", "Go."), ("go um", "Go"), ("go um now", "Go now"),
                              ("go um (later)", "Go (later)"), ("go um, please", "Go, please"),
                              ("go um.\u0301 now", "Go .\u0301 now")):
            self.assertEqual(editplan.apply_edits(edits, raw), expected)
        for raw, replacement, expected in (("go um, now", "", "go now"), ("go um uh.", "", "go."),
                                           ("go um uh", "", "go"), ("go um, now", "(", "go ( now"),
                                           ("go um, now", ".", "go. now")):
            edits = [dict(s=1, e=2, r="", c="filler"), dict(s=2, e=3, r=replacement, c="punctuation")]
            self.assertEqual(editplan.apply_edits(edits, raw), expected)

    def test_mechanical_edits_preserve_symbols(self):
        for raw, edit, vocabulary in (
            ("um 😀 send the message", dict(s=0, e=2, r="", c="filler"), []),
            ("yes 😀 yes send the message", dict(s=0, e=2, r="", c="repetition"), []),
            ("Use pop 😀 tart for the announcement tomorrow", dict(s=1, e=4, r="Poptart", c="vocabulary"), ["Poptart"]),
        ):
            self.assertTrue(editplan.plan_violation([edit], raw, vocabulary_terms=vocabulary).startswith("unsafeCategory"))

    def test_literal_boundaries_match_native_fixtures(self):
        cases = json.loads((ROOT / "Evals/fixtures/literal-boundaries.json").read_text())
        self.assertTrue(cases)
        for case in cases:
            with self.subTest(case=case["id"]):
                edits, reserved = case["plan"]["e"], case["reservedEdits"]
                violation = editplan.plan_violation(edits, case["raw"], reserved_edits=reserved)
                if case["reject"]:
                    self.assertIsNotNone(violation)
                    self.assertTrue(violation.startswith("unsafeCategory"))
                else:
                    self.assertIsNone(violation)
                    self.assertEqual(editplan.resolve(case["raw"], edits, reserved), case["expected"])
        self.assertIsNone(editplan.plan_violation([dict(s=1, e=6, r="13", c="correction")],
            "send 12, I mean 13 cartons tomorrow", model_authored=False))

    def test_quality_threshold_boundaries_and_stale_review(self):
        import run as evaluation
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from verify_release_inputs import compare_quality
        manifest = evaluation.frozen_suite()
        reviewed = dict(manifest, independentReview=dict(reviewer="test", reviewedAt="test", evidence="test",
                                                       suiteSHA256=evaluation.review_digest(manifest)))
        figures = {key: dict(applicable=48, passed=48) for key in evaluation.RELEASE_MINIMUM_RATES}
        figures["editPlanExact"]["passed"] = 46
        self.assertTrue(evaluation.quality_gate(figures, reviewed)["passed"])
        for name in figures:
            broken = dict(figures, **{name: dict(applicable=48, passed=45 if name == "editPlanExact" else 47)})
            self.assertIn(name, evaluation.quality_gate(broken, reviewed)["failures"])
            empty = dict(figures, **{name: dict(applicable=0, passed=0)})
            self.assertIn(name, evaluation.quality_gate(empty, reviewed)["failures"])
        stale = dict(reviewed, gold=dict(count=48, sha256="different"))
        self.assertIn("independentReview", evaluation.quality_gate(figures, stale)["failures"])
        compare_quality(figures, figures)
        stronger = dict(figures, editPlanExact=dict(applicable=48, passed=48))
        compare_quality(stronger, figures)
        with self.assertRaises(ValueError):
            compare_quality(figures, stronger)

    def test_release_quality_recomputes_scores_and_requires_independent_review(self):
        import run as evaluation
        import baseline
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from verify_release_inputs import validate_quality
        directory = evaluation.RELEASE_DIRECTORY
        gold, adversarial = load(directory / "gold.jsonl"), load(directory / "adversarial.jsonl")
        rows = [dict(id=r["id"], output=r["expected"], outcome="cleaned", editPlan=r["editPlan"], elapsedMilliseconds=1) for r in gold]
        rows += [dict(id=r["id"], output=r["raw"], outcome="fallback", fallbackReason="unsafeEditPlan", elapsedMilliseconds=1) for r in adversarial]
        for row in rows:
            row.update(inputTokens=32, maximumInputTokens=2048)
        probes = [dict(id=f"{r['id']}#probe-{i}", output=r['raw'], outcome="fallback",
                       fallbackReason="unsafeEditPlan", validationError=evaluation.PROBE_ERRORS[r['category']],
                       elapsedMilliseconds=1) for r in adversarial for i, _ in enumerate(r.get('probeEditPlans', []))]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            runner = Path(temporary) / "runner"
            runner.write_bytes(b"trusted-test-runner")
            resources = path.with_name("native-resources.txt")
            resources.write_text(" 2048 maximum resident set size\n 1024 peak memory footprint\n")
            identity = dict(**baseline.runtime_identity(runner), modelFiles={"test": "test"}, goldSHA256=evaluation.digest(directory / "gold.jsonl"), adversarialSHA256=evaluation.digest(directory / "adversarial.jsonl"))
            path.write_text("".join(json.dumps(r) + "\n" for r in rows))
            unreviewed = dict(evaluation.frozen_suite(), independentReview=None)
            with patch.object(evaluation, "frozen_suite", return_value=unreviewed):
                report = evaluation.build_report(directory / "gold.jsonl", directory / "adversarial.jsonl", path, True)
                report["executionIdentity"] = identity
                report["nativeProbes"] = probes
                report["measurements"] = baseline.resource_measurements(rows, resources.read_text())
                self.assertEqual(report["releaseGate"]["failures"], ["independentReview"])
                with self.assertRaises(ValueError):
                    validate_quality(report, path, runner, 2048)
            reviewed = dict(evaluation.frozen_suite(), independentReview=dict(reviewer="test-only reviewer", reviewedAt="test", evidence="test-only", suiteSHA256=evaluation.review_digest(evaluation.frozen_suite())))
            with patch.object(evaluation, "frozen_suite", return_value=reviewed):
                report = evaluation.build_report(directory / "gold.jsonl", directory / "adversarial.jsonl", path, True)
                report["executionIdentity"] = identity
                report["nativeProbes"] = probes
                report["measurements"] = baseline.resource_measurements(rows, resources.read_text())
                validate_quality(report, path, runner, 2048)
                for field, values in {"maximumInputTokens": [None, True, 0, 128, 2048.0],
                                      "inputTokens": [None, True, 0, -1, 2049, 32.0]}.items():
                    for value in values:
                        with self.subTest(field=field, value=value):
                            altered = [dict(row) for row in rows]
                            altered[0][field] = value
                            path.write_text("".join(json.dumps(row) + "\n" for row in altered))
                            with self.assertRaisesRegex(ValueError, "token counts"):
                                validate_quality(report, path, runner, 2048)
                path.write_text("".join(json.dumps(row) + "\n" for row in rows))
                with self.assertRaisesRegex(ValueError, "token counts"):
                    validate_quality(report, path, runner, 128)
                for invalid_ceiling in [None, True, 0, -1, 2048.0]:
                    with self.assertRaisesRegex(ValueError, "positive shipping"):
                        validate_quality(report, path, runner, invalid_ceiling)
                with self.assertRaises(ValueError):
                    validate_quality(dict(report, measurements=dict(report["measurements"], peakFootprintBytes=999)), path, runner, 2048)
                resources.unlink()
                with self.assertRaises(OSError):
                    validate_quality(report, path, runner, 2048)
                resources.write_text(" 2048 maximum resident set size\n 1024 peak memory footprint\n")
                with self.assertRaises(ValueError):
                    validate_quality(dict(report, evaluationMode="gemma3"), path, runner, 2048)
                for missing in (None, [], probes[:-1], probes + probes[:1]):
                    with self.assertRaises(ValueError):
                        validate_quality(dict(report, nativeProbes=missing), path, runner, 2048)
                with self.assertRaises(ValueError):
                    validate_quality(dict(report, executionIdentity=dict(identity, sourceSHA256={})), path, runner, 2048)
                with self.assertRaises(ValueError):
                    validate_quality(dict(report, schemaVersion=2), path, runner, 2048)
                forged = dict(report, editPlanExact=dict(applicable=48, passed=0))
                with self.assertRaises(ValueError):
                    validate_quality(forged, path, runner, 2048)
                # All-fallback models cannot pass quality, even when every raw output is preserved.
                for row, fixture in zip(rows, gold + adversarial):
                    row.update(output=fixture["raw"], outcome="fallback", fallbackReason="unsafeEditPlan")
                path.write_text("".join(json.dumps(r) + "\n" for r in rows))
                failed = evaluation.build_report(directory / "gold.jsonl", directory / "adversarial.jsonl", path, True)
                failed["executionIdentity"] = identity
                failed["nativeProbes"] = probes
                failed["measurements"] = baseline.resource_measurements(rows, resources.read_text())
                self.assertIn("editPlanExact", failed["releaseGate"]["failures"])
                with self.assertRaises(ValueError):
                    validate_quality(failed, path, runner, 2048)
                with self.assertRaises(ValueError):
                    validate_quality(report, path, runner, 2048)
                path.write_text("".join(json.dumps(r) + "\n" for r in rows[:-1]))
                with self.assertRaises(ValueError):
                    validate_quality(report, path, runner, 2048)

    def test_adversarial_labels_require_real_scalars_and_native_probe_contract(self):
        import run as evaluation
        fixtures = load(evaluation.RELEASE_DIRECTORY / "adversarial.jsonl")
        for record in fixtures:
            evaluation.validate_adversarial(record)
            if record["category"] == "controlCharacters":
                escaped = dict(record, raw=record["raw"].encode("unicode_escape").decode())
                with self.assertRaisesRegex(ValueError, "actual Cc"):
                    evaluation.validate_adversarial(escaped)
            if record["allowedCleanedOutputs"]:
                capital = record["raw"][0].upper() + record["raw"][1:]
                self.assertIn(capital, record["allowedCleanedOutputs"])
        record = next(r for r in fixtures if r["category"] == "overlappingSpans")
        with self.assertRaises(ValueError):
            evaluation.validate_adversarial(dict(record, probeEditPlans=[]))
        with self.assertRaises(ValueError):
            evaluation.validate_adversarial(dict(record, probeEditPlans=[dict(v=1, e=[])]))
        probes = [dict(id=f"{r['id']}#probe-{i}", output=r['raw'], outcome="fallback",
                       fallbackReason="unsafeEditPlan", validationError=evaluation.PROBE_ERRORS[r['category']],
                       elapsedMilliseconds=1) for r in fixtures for i, _ in enumerate(r.get('probeEditPlans', []))]
        evaluation.validate_native_probes(probes, fixtures)
        for change in (dict(validationError="wrong"), dict(output="changed"), dict(outcome="cleaned"),
                       dict(fallbackReason="cleanupFailed"), dict(elapsedMilliseconds=float("nan"))):
            with self.assertRaises(ValueError):
                evaluation.validate_native_probes([dict(probes[0], **change)] + probes[1:], fixtures)

    def test_release_fixture_freeze_and_training_exclusion(self):
        import run as evaluation
        directory = evaluation.RELEASE_DIRECTORY
        manifest = evaluation.frozen_suite()
        self.assertEqual(manifest["gold"]["count"], 48)
        self.assertEqual(manifest["adversarial"]["count"], 22)
        with tempfile.TemporaryDirectory() as temporary:
            copy = Path(temporary)
            for name in ("gold.jsonl", "adversarial.jsonl", "manifest.json"):
                (copy / name).write_bytes((directory / name).read_bytes())
            (copy / "gold.jsonl").write_text((copy / "gold.jsonl").read_text() + "\n")
            with self.assertRaises(ValueError):
                evaluation.frozen_suite(copy)
        fixture = load(directory / "gold.jsonl")[0]
        leaked = dict(load(CORPUS)[0], id="release-leak", raw=fixture["raw"])
        with self.assertRaises(ValueError):
            prepare_corpus.validate_partitions([leaked], [fixture])

    def test_fixture_integrity_is_deterministic_and_not_a_quality_claim(self):
        first = evaluate([]).stdout
        second = evaluate([]).stdout
        self.assertEqual(first, second)
        report = json.loads(first)
        self.assertEqual(report["mode"], "fixture-integrity")
        self.assertFalse(report["qualityClaim"])
        self.assertEqual(report["goldFixtures"], len(load(GOLD)))
        self.assertEqual(report["adversarialFixtures"], len(load(ADVERSARIAL)))

    def test_span_tokenizer_still_mirrors_the_swift_transcript(self):
        self.assertEqual(editplan.mirror_vector_failures(), [])

    def test_adversarial_coverage_includes_invalid_spans(self):
        adversarial = load(ADVERSARIAL)
        invalid = [record for record in adversarial if record["category"] == "invalidSpans"]
        self.assertEqual(len(invalid), 1)
        span_count = len(editplan.tokenize(invalid[0]["raw"]))
        probes = invalid[0]["probeEditPlans"]
        self.assertGreaterEqual(len(probes), 3)
        for probe in probes:
            edits = editplan.parse_plan(probe)
            self.assertEqual(editplan.bounds_violation(edits, span_count), "invalidBounds")

    def test_mirror_rejects_a_plan_that_exceeds_the_validators_change_budget(self):
        """Regression: this exact plan was certified while the runtime rejects it."""
        raw = "open the pop tart settings"
        edits = [
            {"s": 0, "e": 1, "r": "Open", "c": "capitalization"},
            {"s": 2, "e": 4, "r": "Poptart", "c": "vocabulary"},
            {"s": 5, "e": 5, "r": ".", "c": "punctuation"},
        ]
        # max(8, ceil(26 * 0.35)) = 10, against max("open","Open") +
        # max("pop tart","Poptart") + max("",".") = 4 + 8 + 1 = 13.
        self.assertEqual(editplan.character_count(raw), 26)
        self.assertEqual(editplan.change_budget(raw), 10)
        self.assertEqual(editplan.changed_characters(edits, raw), 13)
        violation = editplan.plan_violation(edits, raw, ["Poptart"])
        self.assertIsNotNone(violation)
        self.assertTrue(violation.startswith("excessiveChange"), violation)
        # The same plan inside a corpus record must abort the whole build.
        record = dict(load(CORPUS)[0])
        record.update({"raw": raw, "clean": "Open the Poptart settings.",
                       "editPlan": {"v": 1, "e": edits}, "vocabularyTerms": ["Poptart"]})
        with self.assertRaises(ValueError) as raised:
            prepare_corpus.build(record, set())
        self.assertIn("excessiveChange", str(raised.exception))

    def test_mirror_enforces_every_validator_rule_not_only_bounds_and_category(self):
        """The rules that were missing before: what the runtime rejects must not pass."""
        long_raw = "um alpha beta gamma delta epsilon zeta eta theta"
        borrowing = dict(
            editplan.DEFAULT_TARGET_CONTEXT, textBeforeCursor="the quarterly summary"
        )
        many = [{"s": i, "e": i, "r": ".", "c": "punctuation"} for i in range(0, 18, 2)]
        cases = [
            ("tooManyEdits", long_raw, many, (), None),
            ("replacementTooLarge", long_raw,
             [{"s": 1, "e": 2, "r": "x" * 65, "c": "capitalization"}], (), None),
            ("unsafeUnicode", long_raw,
             [{"s": 1, "e": 2, "r": "Alpha\u0007", "c": "capitalization"}], (), None),
            ("reservedSpan", long_raw, [{"s": 2, "e": 4, "r": "", "c": "filler"}],
             [{"s": 1, "e": 5, "r": "", "c": "correction"}], None),
            ("copiedTargetContext", long_raw,
             [{"s": 1, "e": 2, "r": "quarterly", "c": "vocabulary"}], (), borrowing),
            # Deleting the only span empties the Dictation without removing filler.
            ("blankOutput", ".", [{"s": 0, "e": 1, "r": "", "c": "punctuation"}], (), None),
        ]
        for expected, raw, edits, reserved, context in cases:
            violation = editplan.plan_violation(edits, raw, (), reserved, context)
            self.assertIsNotNone(violation, expected)
            self.assertTrue(violation.startswith(expected), f"{expected}: got {violation}")

        # Controls: a conservative plan, and the one blank result the validator allows.
        self.assertIsNone(
            editplan.plan_violation(
                [{"s": 0, "e": 1, "r": "", "c": "filler"}], long_raw, (), (), borrowing
            )
        )
        self.assertIsNone(
            editplan.plan_violation([{"s": 0, "e": 2, "r": "", "c": "filler"}], "um uh")
        )

    def test_four_quality_dimensions_are_scored_separately(self):
        gold = load(GOLD)
        adversarial = load(ADVERSARIAL)
        vocabulary_fixtures = [
            record
            for record in gold
            if any(term in record["raw"] for term in record.get("vocabularyTerms", []))
        ]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            path.write_text(
                "".join(
                    json.dumps(record) + "\n" for record in predictions_for(gold, adversarial)
                ),
                encoding="utf-8",
            )
            report = json.loads(evaluate(["--predictions", str(path)]).stdout)

        self.assertEqual(report["mode"], "model-results")
        self.assertTrue(report["qualityClaim"])
        # Four separate figures, never averaged into one number.
        self.assertEqual(
            report["editPlanExact"], {"applicable": len(gold), "passed": len(gold) - 4}
        )
        self.assertEqual(
            report["meaningPreservation"], {"applicable": len(gold), "passed": len(gold) - 1}
        )
        self.assertEqual(
            report["vocabularyPreservation"],
            {"applicable": len(vocabulary_fixtures), "passed": len(vocabulary_fixtures) - 1},
        )
        self.assertEqual(report["contextFit"], {"applicable": len(gold), "passed": len(gold) - 1})
        self.assertEqual(
            report["adversarialSafe"],
            {"applicable": len(adversarial), "passed": len(adversarial) - 1},
        )
        self.assertGreaterEqual(len(vocabulary_fixtures), 2)

    def test_scoring_fails_closed_on_an_incomplete_prediction_file(self):
        gold = load(GOLD)
        adversarial = load(ADVERSARIAL)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            path.write_text(
                "".join(
                    json.dumps(record) + "\n"
                    for record in predictions_for(gold, adversarial)[1:]
                ),
                encoding="utf-8",
            )
            result = evaluate(["--predictions", str(path)], expect_success=False)
        self.assertNotEqual(result.returncode, 0)

    def test_corpus_and_evaluation_utterances_do_not_leak_across_splits(self):
        corpus = load(CORPUS)
        evaluation = [record for path in (ROOT / "Evals/fixtures").rglob("*.jsonl") for record in load(path)]
        prepare_corpus.validate_partitions(corpus, evaluation)
        duplicate = dict(corpus[0], id="leaked", split="test", raw=corpus[0]["raw"].upper())
        with self.assertRaises(ValueError):
            prepare_corpus.validate_partitions(corpus + [duplicate], evaluation)
        with self.assertRaises(ValueError):
            prepare_corpus.validate_partitions(corpus + [dict(corpus[0], id="eval-leak", raw=evaluation[0]["raw"])], evaluation)

    def test_training_vocabulary_contrasts_preserve_leakage_checks(self):
        first = dict(id="first", split="train", raw="open cedar shell", vocabularyTerms=["CedarShell", "OakMap"])
        variant = dict(first, id="variant", vocabularyTerms=["CEDARSHELL", "OakMap"])
        prepare_corpus.validate_partitions([first, variant], [])
        for duplicate in [dict(first, id="repeat"), dict(first, id="reordered", vocabularyTerms=["OakMap", "CedarShell"]),
                          dict(first, id="unrelated", vocabularyTerms=["BirchDesk", "OakMap"]),
                          dict(variant, id="validation", split="valid"), dict(variant, id="test", split="test")]:
            with self.assertRaises(ValueError):
                prepare_corpus.validate_partitions([first, variant, duplicate], [])
        with self.assertRaises(ValueError):
            prepare_corpus.validate_partitions([first, variant], [dict(id="evaluation", raw=first["raw"], vocabularyTerms=[])])
        with self.assertRaises(ValueError):
            prepare_corpus.validate_partitions([variant], [first])

    def test_spoken_fixtures_are_valid_and_synthesis_refuses_unsafe_inputs(self):
        import synthesize_audio
        spoken = load(ROOT / "Evals/fixtures/spoken.jsonl")
        synthesize_audio.validate(spoken)
        result = evaluate(["--gold", "Evals/fixtures/spoken.jsonl"])
        self.assertFalse(json.loads(result.stdout)["qualityClaim"])
        for records in ([], [spoken[0], spoken[0]], [dict(spoken[0], id="../outside")],
                        [dict(spoken[0], provenance={})], [dict(spoken[0], historyRecord="private")],
                        [dict(spoken[0], raw="[[slnc 1000]]")]):
            with self.assertRaises(ValueError):
                synthesize_audio.validate(records)

    def test_prediction_validation_rejects_nonfinite_timings_and_duplicate_ids(self):
        import run as evaluation
        for elapsed in (float("nan"), float("inf"), -1, True):
            with self.assertRaises(ValueError):
                evaluation.validate_prediction("test", dict(outcome="cleaned", output="Text.", elapsedMilliseconds=elapsed))
        records = predictions_for(load(GOLD), load(ADVERSARIAL))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "predictions.jsonl"
            path.write_text("".join(json.dumps(r) + "\n" for r in records + [records[0]]))
            self.assertNotEqual(evaluate(["--predictions", str(path)], expect_success=False).returncode, 0)

    def test_training_targets_are_edit_plans_that_reproduce_the_clean_text(self):
        build_corpus()
        corpus = {record["id"]: record for record in load(CORPUS)}
        clean_texts = {record["clean"] for record in corpus.values()}
        generated = [
            record
            for name in ("train", "valid", "test")
            for record in load(ROOT / f"Training/generated/mlx/{name}.jsonl")
        ]
        self.assertEqual(len(generated), len(corpus))
        for record in generated:
            target = record["messages"][-1]
            self.assertEqual(target["role"], "assistant")
            self.assertTrue(target["content"].endswith(editplan.STOP_MARKER))
            self.assertNotIn(target["content"], clean_texts)
            edits = prepare_corpus.parse_target(target["content"])
            self.assertTrue(all(set(edit) == {"s", "e", "r", "c"} for edit in edits))

    def test_training_prompt_still_matches_the_runtime_prompt(self):
        """The corpus builder embeds CleanupPrompt's text; drift would train the wrong task."""
        if not CLEANUP_PROMPT.exists():
            self.skipTest("the Cleanup package is not present in this checkout")
        source = CLEANUP_PROMPT.read_text(encoding="utf-8")
        marker = re.search(r'stopMarker\s*=\s*"([^"]*)"', source)
        self.assertIsNotNone(marker)
        self.assertEqual(marker.group(1), editplan.STOP_MARKER)
        blocks = [block.strip() for block in re.findall(r'"""\n(.*?)\n\s*"""', source, re.S)]
        self.assertIn(prepare_corpus.SYSTEM.strip(), blocks)
        payload = [block for block in blocks if block.startswith(prepare_corpus.PREAMBLE)]
        self.assertEqual(len(payload), 1)
        self.assertIn("BEGIN_UNTRUSTED_DATA_JSON_UTF8_BYTES=", payload[0])

    def test_training_corpus_generation_is_reproducible(self):
        build_corpus()
        before = {p.name: p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        build_corpus()
        after = {p.name: p.read_bytes() for p in (ROOT / "Training/generated/mlx").glob("*.jsonl")}
        self.assertEqual(before, after)

    def test_corpus_build_rejects_a_plan_that_does_not_reproduce_its_clean_text(self):
        record = dict(load(CORPUS)[0])
        prepare_corpus.build(dict(record), set())
        record["clean"] = record["clean"].replace(".", "!")
        with self.assertRaises(ValueError):
            prepare_corpus.build(record, set())

    def test_corpus_build_rejects_a_model_authored_explicit_correction(self):
        record = dict(load(CORPUS)[0])
        record["editPlan"] = {"v": 1, "e": [{"s": 0, "e": 1, "r": "", "c": "correction"}]}
        with self.assertRaises(ValueError):
            prepare_corpus.build(record, set())

    def test_release_benchmark_fails_closed_without_physical_baseline_and_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    "python3",
                    "Scripts/benchmark_release.py",
                    "--runner",
                    "/missing",
                    "--model",
                    "/missing",
                    "--audio",
                    "/missing",
                    "--output",
                    str(Path(temporary) / "out.json"),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)


class BenchmarkPrivacyTests(unittest.TestCase):
    @staticmethod
    def row():
        return dict(id="fixture", elapsedMilliseconds=800, finalRecognitionMilliseconds=100,
                    cleanupMilliseconds=650, deliveryMilliseconds=50, footprintBytes=1000,
                    peakFootprintBytes=1200, mlxActiveBytes=500, bothModelsResident=True,
                    historyReadback=True, settingsReadback=True, historyRecordID="record",
                    outcome="cleaned", deliveredText="Hello.", deliveryMode="controlled", cleanupTokenCeiling=512)

    def test_release_model_contract_requires_packed_qwen_and_complete_vocabulary_assets(self):
        import struct
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from build_model_manifest import validate_release_models
        config = json.loads((ROOT / "Models/production-config.json").read_text())
        config["releaseStatus"] = "release"
        model_config = dict(model_type="qwen3_5", quantization=dict(bits=4, group_size=64, mode="affine"),
                            text_config=dict(hidden_size=2048, num_hidden_layers=24, intermediate_size=6144))
        header = {"layer.weight": dict(dtype="U32", shape=[2, 8], data_offsets=[0, 64]),
                  "layer.scales": dict(dtype="F32", shape=[2, 1], data_offsets=[64, 72]),
                  "layer.biases": dict(dtype="F32", shape=[2, 1], data_offsets=[72, 80])}
        with tempfile.TemporaryDirectory() as temporary:
            pack = Path(temporary)
            base = pack / "cleanup/base"
            base.mkdir(parents=True)
            config_path = base / "config.json"
            config_path.write_text(json.dumps(model_config))
            weight_path = base / "model.safetensors"
            def write_weights(value):
                encoded = json.dumps(value).encode()
                weight_path.write_bytes(struct.pack("<Q", len(encoded)) + encoded + bytes(80))
            write_weights(header)
            # Separate higher-precision adapters are excluded from the base packing contract.
            adapter = pack / "cleanup/adapters/adapters.safetensors"
            adapter.parent.mkdir()
            adapter.write_bytes(b"separate F32 adapter; native evaluation validates its contents")
            ctc = pack / "recognition/ctc"
            ctc.mkdir(parents=True)
            required = []
            for bundle in ("MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"):
                for name in ("coremldata.bin", "model.mil", "metadata.json", "weights/weight.bin"):
                    path = ctc / bundle / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"synthetic bundle component")
                    required.append(path)
            for name in ("vocab.json", "tokenizer.json"):
                path = ctc / name
                path.write_text('{"synthetic": 1}')
                required.append(path)
            validate_release_models(pack, config)
            for path in required:
                original = path.read_bytes()
                path.unlink()
                with self.subTest(missing=path.name), self.assertRaises((ValueError, OSError)):
                    validate_release_models(pack, config)
                path.write_bytes(original)
            for bad in (dict(model_config, quantization=None),
                        dict(model_config, quantization=dict(bits=8, group_size=64, mode="affine")),
                        dict(model_config, model_type="gemma3"),
                        dict(model_config, text_config=dict(hidden_size=1024))):
                config_path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError): validate_release_models(pack, config)
            config_path.write_text(json.dumps(model_config))
            for name, change in (("layer.weight", dict(dtype="F32")),
                                 ("layer.scales", dict(shape=[2, 2]))):
                bad = json.loads(json.dumps(header))
                bad[name].update(change)
                write_weights(bad)
                with self.assertRaises(ValueError): validate_release_models(pack, config)
            weight_path.write_bytes(b"truncated")
            with self.assertRaises(ValueError): validate_release_models(pack, config)
            validate_release_models(pack, dict(config, releaseStatus="unreleased"))

    def test_per_file_manifest_and_benchmark_evidence_match_shipping_bytes(self):
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from build_model_manifest import build, validate_manifest
        from benchmark_release import execution_identity
        from verify_release_inputs import validate_benchmark_evidence
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pack, audio = root / "pack", root / "audio"
            audio.mkdir()
            files = {"recognition/unified/Encoder.mlmodelc/weights/weight.bin": b"recognition",
                     "recognition/ctc/tokenizer.json": b"tokenizer",
                     "vad/model.bin": b"voice activity",
                     "cleanup/config.json": b"{}", "cleanup/tokenizer.json": b"{}",
                     "cleanup/tokenizer_config.json": b"{}", "cleanup/model.safetensors": b"cleanup"}
            for name, value in files.items():
                target = pack / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
            config = {"recognition": {"license": "CC-BY-4.0", "vad": {"license": "MIT"}},
                      "cleanup": {"license": "Apache-2.0"}}
            manifest, summaries = build(pack, config, "https://models.example/1.0", "1.0.0", "1.0.0", "2.0.0", 512)
            self.assertEqual({a['relativePath'] for a in manifest['artifacts']}, set(files))
            self.assertEqual(summaries['recognition']['byteSize'], len(b'recognitiontokenizervoice activity'))
            validate_manifest(manifest, pack, 512, config)
            for field in ('identity', 'version', 'minimumApplicationVersion', 'maximumApplicationVersion'):
                missing = {key: value for key, value in manifest.items() if key != field}
                with self.subTest(missing=field), self.assertRaises(ValueError):
                    validate_manifest(missing, pack, 512, config)
            for identity in ('', '../escape', 'pack/name', 'pack.name', 'pack name', None, 123):
                with self.subTest(identity=identity), self.assertRaises(ValueError):
                    validate_manifest(dict(manifest, identity=identity), pack, 512, config)
            for field in ('version', 'minimumApplicationVersion', 'maximumApplicationVersion'):
                for version in ('', '1', '1..0', '.1.0', '1.0.', '-1.0', '1.0-beta',
                                '１.０', '9223372036854775808.0', None, 123):
                    with self.subTest(field=field, version=version), self.assertRaises(ValueError):
                        validate_manifest(dict(manifest, **{field: version}), pack, 512, config)
                    versions = dict(version='1.0.0', minimum='1.0.0', maximum='2.0.0')
                    versions[dict(version='version', minimumApplicationVersion='minimum',
                                  maximumApplicationVersion='maximum')[field]] = version
                    with self.subTest(builder=versions), self.assertRaises(ValueError):
                        build(pack, config, 'https://models.example/1.0', ceiling=512, **versions)
            with self.assertRaises(ValueError):
                validate_manifest(dict(manifest, minimumApplicationVersion='2.0.1',
                                       maximumApplicationVersion='2.0'), pack, 512, config)
            with self.assertRaises(ValueError):
                build(pack, config, 'https://models.example/1.0', '1.0', '2.0.1', '2.0', 512)
            # Native versions allow two or more components and compare missing/trailing zeros equally.
            equivalent, _ = build(pack, config, 'https://models.example/1.0',
                                  '9223372036854775807.0', '01.0.0.0', '1.0', 512)
            validate_manifest(dict(equivalent, identity='模型-e\u0301_1'), pack, 512, config)
            vad_entry = next(a for a in manifest['artifacts'] if a['relativePath'].startswith('vad/'))
            self.assertEqual(vad_entry['license'], dict(name='MIT', url='https://opensource.org/license/mit'))
            mislabeled = json.loads(json.dumps(manifest))
            next(a for a in mislabeled['artifacts'] if a['relativePath'].startswith('vad/'))['license'] = dict(
                name='CC-BY-4.0', url='https://creativecommons.org/licenses/by/4.0/')
            with self.assertRaises(ValueError):
                validate_manifest(mislabeled, pack, 512, config)
            for bad in (dict(manifest, artifacts=manifest['artifacts'][:-1]),
                        dict(manifest, artifacts=manifest['artifacts'] + manifest['artifacts'][:1])):
                with self.assertRaises(ValueError):
                    validate_manifest(bad, pack, 512, config)
            (pack / "manifest.json").write_text(json.dumps(manifest))
            fixtures, runner = root / "fixtures.jsonl", root / "runner"
            fixtures.write_text('{"id":"fixture"}\n')
            runner.write_bytes(b"measured runner")
            (audio / "fixture.wav").write_bytes(b"measured fixture")
            report = dict(executionIdentity=execution_identity(runner, pack, audio, fixtures))
            validate_benchmark_evidence(report, runner, pack, audio, fixtures)
            for target in (pack / "recognition/unified/Encoder.mlmodelc/weights/weight.bin",
                           pack / "cleanup/model.safetensors", pack / "vad/model.bin", pack / "manifest.json",
                           audio / "fixture.wav", runner, fixtures):
                original = target.read_bytes()
                target.write_bytes(original + b" ")
                with self.assertRaises(ValueError):
                    validate_benchmark_evidence(report, runner, pack, audio, fixtures)
                target.write_bytes(original)
            vad = pack / "vad/model.bin"
            content = vad.read_bytes()
            vad.unlink()
            vad.parent.rmdir()
            with self.assertRaises(ValueError):
                validate_benchmark_evidence(report, runner, pack, audio, fixtures)
            no_vad = dict(executionIdentity=execution_identity(runner, pack, audio, fixtures))
            vad.parent.mkdir()
            vad.write_bytes(content)
            with self.assertRaises(ValueError):
                validate_benchmark_evidence(no_vad, runner, pack, audio, fixtures)
            with self.assertRaises(ValueError):
                validate_benchmark_evidence({}, runner, pack, audio, fixtures)

    def test_benchmark_summary_and_release_measurements(self):
        sys.path.insert(0, str(ROOT / "Scripts/release"))
        from benchmark_release import summarize
        from verify_release_inputs import validate_measurements
        row = self.row()
        summary = summarize([row], ["fixture"])
        self.assertEqual(summary["p99Milliseconds"], 800)
        self.assertEqual(summary["peakFootprintBytes"], 1200)
        hardware = dict(chip="Apple M5 Pro", memoryBytes=48 * 1024**3,
                        architecture="arm64", virtualized=False)
        report = dict(summary, hardware=hardware, macOS="26.0", results=[row])
        measurements = dict(benchmarkHardware=hardware, benchmarkMacOS="26.0",
                            benchmarkP99Milliseconds=800, benchmarkPeakFootprintBytes=1200,
                            benchmarkSteadyStateFootprintBytes=1000, cleanupTokenCeiling=512)
        validate_measurements(measurements, report, ["fixture"])
        for key in measurements:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_measurements(dict(measurements, **{key: 999}), report, ["fixture"])
        with self.assertRaises(ValueError):
            validate_measurements(measurements, dict(report, p99Milliseconds=1), ["fixture"])
        with self.assertRaises(ValueError):
            validate_measurements(measurements, dict(report, hardware=dict(hardware, virtualized=True)), ["fixture"])

    def test_incomplete_or_invalid_benchmark_evidence_is_rejected(self):
        from benchmark_release import summarize
        for rows in ([], [self.row(), self.row()], [dict(self.row(), id="other")]):
            with self.assertRaises(ValueError):
                summarize(rows, ["fixture"])
        for patch in (dict(elapsedMilliseconds=float("nan")), dict(cleanupMilliseconds=-1),
                      dict(footprintBytes=True), dict(peakFootprintBytes=1), dict(bothModelsResident=False),
                      dict(historyReadback=False), dict(settingsReadback=False), dict(deliveredText="")):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                summarize([dict(self.row(), **patch)], ["fixture"])
        rows = [dict(self.row(), id=str(i), historyRecordID=str(i), elapsedMilliseconds=i+1) for i in range(100)]
        self.assertEqual(summarize(rows, [str(i) for i in range(100)])["p99Milliseconds"], 99)

    def test_benchmark_hypothesis_fallback_preserves_null_unexecuted_cleanup(self):
        from benchmark_release import summarize
        fallback = dict(self.row(), id="fallback", historyRecordID="fallback-record",
                        outcome="recognitionHypothesis", rawTranscript=None, cleanupMilliseconds=None,
                        elapsedMilliseconds=1410, finalRecognitionMilliseconds=1400, deliveryMilliseconds=10)
        rows = [self.row(), fallback]
        summary = summarize(rows, ["fixture", "fallback"])
        self.assertTrue(summary["passed"])
        self.assertEqual(summary["p99Milliseconds"], 1410)
        self.assertEqual(summary["sampleCount"], 2)
        self.assertIsNone(fallback["cleanupMilliseconds"])
        self.assertIsNone(fallback["rawTranscript"])
        for patch in (dict(cleanupMilliseconds=0), dict(rawTranscript="partial"),
                      dict(finalRecognitionMilliseconds=None), dict(elapsedMilliseconds=None),
                      dict(outcome="cleaned")):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                summarize([dict(fallback, **patch)], ["fallback"])
        for field in ("cleanupMilliseconds", "rawTranscript"):
            missing = dict(fallback)
            del missing[field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                summarize([missing], ["fallback"])

    def test_deny_requires_successful_model_cleanup(self):
        sys.path.insert(0, str(ROOT / "Scripts/privacy"))
        from verify_evidence import deny_results
        self.assertTrue(deny_results([self.row()], ["fixture"])["dictationProven"])
        with self.assertRaises(ValueError):
            deny_results([dict(self.row(), outcome="rawTranscript")], ["fixture"])

    def test_traffic_requires_complete_capture_and_download(self):
        sys.path.insert(0, str(ROOT / "Scripts/privacy"))
        from verify_evidence import traffic_results
        phases = dict(captureReady=1, appStarted=2, downloadStarted=3, downloadFinished=4, captureFinished=5)
        stats = "1 packets captured\n0 packets dropped by kernel\n"
        timed = traffic_results(["3.5 packet"], stats, phases, True)
        self.assertTrue(timed["passed"])
        self.assertFalse(timed["destinationsVerified"])
        self.assertEqual(timed["scope"], "network-silence-outside-explicit-download")
        self.assertFalse(traffic_results(["2.5 packet", "3.5 packet"], stats.replace("1 packets", "2 packets"), phases, True)["passed"])
        for lines, log, marks, installed in (([], stats, phases, True), (["3.5 packet"], "", phases, True),
            (["3.5 packet"], stats.replace("0 packets", "1 packets"), phases, True),
            (["3.5 packet"], stats, {}, True), (["3.5 packet"], stats, phases, False),
            (["garbage"], stats, phases, True)):
            with self.assertRaises(ValueError):
                traffic_results(lines, log, marks, installed)


if __name__ == "__main__":
    unittest.main()
