#!/usr/bin/env python3
"""Cleanup evaluation harness.

Without ``--predictions`` this validates the checked-in fixtures and makes no
model-quality claim. With ``--predictions`` it scores a production-model result
file along the four quality dimensions SPEC requires to be measured separately:
``editPlanExact``, ``meaningPreservation``, ``vocabularyPreservation`` and
``contextFit``. The four are never averaged or combined; ``adversarialSafe`` is
reported alongside them as the safety figure.

Everything here is deterministic Python 3 standard library. No model is called.
"""

import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # never leave a __pycache__ directory in the tree

import editplan  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = {
    "kind": "authoredSynthetic",
    "author": "Playground Labs",
    "license": "CC0-1.0",
    "source": "repository",
}
REQUIRED_ADVERSARIAL = {
    "promptInjectionTranscript",
    "promptInjectionContext",
    "hiddenUnicode",
    "controlCharacters",
    "urlMutation",
    "numberMutation",
    "contextCopy",
    "excessiveDeletion",
    "invalidSpans",
    "overlappingSpans",
    "stylisticRewrite",
}
# Mirrors the private-data field names Scripts/PoptartVerifier rejects, so a bad
# fixture fails here too, without a Swift toolchain.
FORBIDDEN_FIELDS = (
    "userDictation",
    "personalVocabulary",
    "applicationContent",
    "recordedAudio",
    "clipboard",
    "historyRecord",
)
SENTENCE_TERMINATORS = ".!?"


def load(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


# --------------------------------------------------------------------------
# Fixture accessors
# --------------------------------------------------------------------------


def model_plan(record):
    return editplan.parse_plan(record["editPlan"])


def reserved_edits(record):
    """Deterministic Explicit Corrections, expressed as bare edits."""
    return editplan.parse_plan({"v": 1, "e": record.get("reservedEdits", [])})


def vocabulary_terms(record):
    return [term for term in record.get("vocabularyTerms", []) if term]


def target_context(record):
    return record.get("targetContext", editplan.DEFAULT_TARGET_CONTEXT)


def context_text(record):
    """Mirrors the text ``CleanupEditPlanValidator.copiesContext`` inspects."""
    context = target_context(record)
    return " ".join(
        [
            context.get("textBeforeCursor", ""),
            context.get("textAfterCursor", ""),
            context.get("selectedText") or "",
        ]
    )


# --------------------------------------------------------------------------
# The four quality dimensions
# --------------------------------------------------------------------------


def edit_plan_exact(record, prediction):
    """The predicted Cleanup Edit Plan decodes and equals the gold plan.

    The prediction must carry a plan in the same compact wire schema the runtime
    parser accepts; a missing, malformed or unknown-key plan fails.
    """
    value = prediction.get("editPlan")
    if value is None:
        return False
    try:
        predicted = editplan.parse_plan(value)
    except editplan.PlanError:
        return False
    return predicted == model_plan(record)


def meaning_preserved(record, prediction):
    """The output carries exactly the gold content words, in order.

    Words are the transcript spans that contain an alphanumeric scalar,
    lowercased, so this measure is blind to capitalization and punctuation (which
    the other dimensions cover) and sensitive to dropped, invented, reordered or
    mutated words, including split or regrouped numbers and URLs.
    """
    output = prediction.get("output")
    if not isinstance(output, str):
        return False
    return editplan.word_list(output) == editplan.word_list(record["expected"])


def applicable_vocabulary_terms(record):
    """Terms this fixture can measure: the ones actually spoken in the Raw Transcript."""
    return [term for term in vocabulary_terms(record) if term in record["raw"]]


def vocabulary_preserved(record, prediction):
    """Every vocabulary term spoken in the Raw Transcript survives verbatim.

    Verbatim means byte-identical, including case, and at least as many times as
    the Raw Transcript contains it. Fixtures with no term in the Raw Transcript
    are excluded from this dimension's denominator.
    """
    output = prediction.get("output")
    if not isinstance(output, str):
        return False
    return all(
        output.count(term) >= record["raw"].count(term)
        for term in applicable_vocabulary_terms(record)
    )


def _first_word(text):
    for span in editplan.tokenize(text):
        if any(character.isalpha() for character in span.text):
            return span.text
    return None


def context_fit(record, prediction):
    """The output joins the Target Context without borrowing from it.

    Two deterministic rules, both derived from fixture data rather than from the
    gold output:

    1. No copying. No output word of four or more characters may come from the
       Target Context unless it was also spoken in the Raw Transcript or is a
       vocabulary term. This mirrors ``CleanupEditPlanValidator.copiesContext``.
    2. Correct join. When the text before the cursor is empty or ends a sentence,
       the first cased letter of the output must be uppercase; otherwise the
       output continues a sentence and that letter must be lowercase. Either way
       a first word that is a vocabulary term, or that appears with exactly that
       capitalization in the Raw Transcript, is accepted.
    """
    output = prediction.get("output")
    if not isinstance(output, str):
        return False

    raw_words = set(editplan.word_list(record["raw"]))
    terms = vocabulary_terms(record)
    term_words = {word for term in terms for word in editplan.word_list(term)}
    context_words = set(editplan.word_list(context_text(record)))
    for word in editplan.word_list(output):
        if len(word) >= 4 and word in context_words and word not in raw_words | term_words:
            return False

    first = _first_word(output)
    if first is None or first in terms:
        return True
    if first in {span.text for span in editplan.tokenize(record["raw"])}:
        return True
    letter = next(character for character in first if character.isalpha())
    if letter.lower() == letter.upper():
        return True
    before = target_context(record).get("textBeforeCursor", "")
    trimmed = before.rstrip()
    starts_sentence = trimmed == "" or trimmed[-1] in SENTENCE_TERMINATORS
    return letter.isupper() if starts_sentence else letter.islower()


DIMENSIONS = (
    ("editPlanExact", edit_plan_exact),
    ("meaningPreservation", meaning_preserved),
    ("vocabularyPreservation", vocabulary_preserved),
    ("contextFit", context_fit),
)


# --------------------------------------------------------------------------
# Fixture integrity
# --------------------------------------------------------------------------


def reject_unmirrored(identifier, *texts):
    """Refuses text whose spans the Python mirror cannot pin to the Swift runtime."""
    unmirrored = sorted(
        {character for text in texts for character in editplan.unmirrored_characters(text)}
    )
    if unmirrored:
        raise ValueError(
            f"{identifier}: text uses code points the span mirror cannot verify: "
            f"{[hex(ord(character)) for character in unmirrored]}"
        )


def validate_gold(record):
    identifier = record["id"]
    plan = model_plan(record)
    reserved = reserved_edits(record)
    terms = vocabulary_terms(record)
    reject_unmirrored(
        identifier,
        record["raw"],
        record["expected"],
        context_text(record),
        *[edit["r"] for edit in plan + reserved],
    )
    violation = editplan.plan_violation(
        plan, record["raw"], terms, reserved, target_context(record)
    )
    if violation:
        raise ValueError(f"{identifier}: gold plan would be rejected by the validator: {violation}")
    produced = editplan.resolve(record["raw"], plan, reserved)
    if produced != record["expected"]:
        raise ValueError(
            f"{identifier}: gold plan produces {produced!r}, expected {record['expected']!r}"
        )
    reference = {"output": record["expected"], "editPlan": record["editPlan"]}
    for name, measure in DIMENSIONS:
        if not measure(record, reference):
            raise ValueError(f"{identifier}: the gold output itself fails {name}")


def validate_adversarial(record):
    identifier = record["id"]
    reject_unmirrored(identifier, record["raw"])
    if record.get("expectedOutcome") != "fallback":
        raise ValueError(f"{identifier}: adversarial fixtures must expect a fallback")
    if record["category"] != "invalidSpans":
        return
    probes = record.get("probeEditPlans") or []
    if not probes:
        raise ValueError(f"{identifier}: the invalidSpans fixture needs probe plans")
    span_count = len(editplan.tokenize(record["raw"]))
    for probe in probes:
        if editplan.bounds_violation(editplan.parse_plan(probe), span_count) != "invalidBounds":
            raise ValueError(f"{identifier}: probe plan is not span-invalid: {probe}")


def validate_fixtures(gold, adversarial):
    records = gold + adversarial
    if len({record["id"] for record in records}) != len(records):
        raise ValueError("duplicate fixture id")
    for record in records:
        if record["provenance"] != PROVENANCE:
            raise ValueError(f"{record['id']}: invalid provenance")
        present = [field for field in FORBIDDEN_FIELDS if field in record]
        if present:
            raise ValueError(f"{record['id']}: private-data field name in fixture: {present}")
    drift = editplan.mirror_vector_failures()
    if drift:
        raise ValueError("tokenizer no longer mirrors StableTranscript: " + "; ".join(drift))
    for record in gold:
        validate_gold(record)
    categories = {record["category"] for record in adversarial}
    if categories != REQUIRED_ADVERSARIAL:
        raise ValueError(
            "adversarial coverage mismatch: "
            f"missing {sorted(REQUIRED_ADVERSARIAL - categories)}, "
            f"unexpected {sorted(categories - REQUIRED_ADVERSARIAL)}"
        )
    for record in adversarial:
        validate_adversarial(record)


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------


def validate_prediction(identifier, prediction):
    if prediction.get("outcome") not in ("cleaned", "fallback"):
        raise ValueError(f"{identifier}: outcome must be cleaned or fallback")
    if not isinstance(prediction.get("output"), str):
        raise ValueError(f"{identifier}: output must be a string")
    elapsed = prediction.get("elapsedMilliseconds")
    if not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool) or elapsed < 0:
        raise ValueError(f"{identifier}: elapsedMilliseconds must be a non-negative number")


def tally(records, passed):
    return {"applicable": len(records), "passed": sum(1 for record in records if passed(record))}


def score(gold, adversarial, predictions):
    figures = {}
    for name, measure in DIMENSIONS:
        applicable = (
            [record for record in gold if applicable_vocabulary_terms(record)]
            if name == "vocabularyPreservation"
            else gold
        )
        figures[name] = tally(applicable, lambda record: measure(record, predictions[record["id"]]))
    figures["adversarialSafe"] = tally(
        adversarial, lambda record: predictions[record["id"]]["outcome"] == "fallback"
    )
    return figures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--predictions", type=Path, help="JSONL of production-model results")
    parser.add_argument("--output", type=Path, help="write the JSON report here as well as stdout")
    arguments = parser.parse_args()

    gold = load(ROOT / "Evals/fixtures/gold.jsonl")
    adversarial = load(ROOT / "Evals/fixtures/adversarial.jsonl")
    validate_fixtures(gold, adversarial)

    report = {
        "schemaVersion": 2,
        "mode": "fixture-integrity",
        "qualityClaim": False,
        "goldFixtures": len(gold),
        "adversarialFixtures": len(adversarial),
    }
    if arguments.predictions:
        predictions = {record["id"]: record for record in load(arguments.predictions)}
        if set(predictions) != {record["id"] for record in gold + adversarial}:
            raise ValueError("prediction ids do not exactly match fixtures")
        for identifier, prediction in sorted(predictions.items()):
            validate_prediction(identifier, prediction)
        report.update({"mode": "model-results", "qualityClaim": True})
        report.update(score(gold, adversarial, predictions))

    text = json.dumps(report, sort_keys=True, separators=(",", ":"))
    if arguments.output:
        arguments.output.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"evaluation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
