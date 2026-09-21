#!/usr/bin/env python3
"""Deterministic Python mirror of the Cleanup Edit Plan wire format.

The evaluation harness and the training corpus builder both need to answer one
question without a model and without a Swift toolchain: *would the runtime accept
this Cleanup Edit Plan, and does applying it to this Raw Transcript produce this
text?* Four pieces of the Swift runtime are mirrored here, and each must stay in
step with its original:

* ``tokenize``       mirrors ``StableTranscript.tokenize``
                     (Packages/Cleanup/Sources/Cleanup/StableTranscript.swift)
* ``apply_edits``    mirrors ``CleanupEditApplier.apply``
                     (Packages/Cleanup/Sources/Cleanup/EditPlanValidator.swift)
* ``parse_plan``     mirrors ``BoundedEditPlanParser.decode``'s structural gate
                     (Packages/Cleanup/Sources/Cleanup/EditPlan.swift)
* ``plan_violation`` mirrors ``CleanupEditPlanValidator.validate`` in full: every
                     rule, in the validator's own order, so a plan accepted here
                     is a plan the runtime accepts. Returning only a subset of
                     the rules once let the harness certify plans production
                     rejects with ``excessiveChange``, so partial mirrors of
                     ``validate`` are a defect, not a simplification.

``MIRROR_VECTORS`` pins the tokenizer against Swift behaviour, including the exact
Unicode vector asserted by ``StableTranscriptTests``. Both ``Evals/run.py`` and
``Scripts/test_tooling.py`` check the vectors, so a silent divergence in this file
fails the tooling suite rather than corrupting fixtures.

The mirror was differentially tested against the compiled Swift originals: 18,000
random strings drawn from the whole of Unicode for the tokenizer and applier, and
6,097 plans against the real ``CleanupEditPlanValidator``, covering all ten
``CleanupEditValidationError`` cases. Two residual limitations remain, and
``unmirrored_characters`` refuses any text that can hit the first:

* Python's bundled Unicode tables are older than the ones Foundation uses, so a
  code point unassigned here may be a letter there.
* U+11A3A ZANABAZAR SQUARE CLUSTER-INITIAL LETTER RA joins a following letter in
  Foundation but not a following symbol, punctuation or space.

Everything is pure Python 3 standard library and free of model calls.
"""

import math
import re
import unicodedata

# Unicode ``White_Space=Yes``. Swift's ``Character.isWhitespace`` uses this
# property; Python's ``str.isspace`` does not match it (it accepts U+001C-U+001F),
# so the set is spelled out rather than inferred.
WHITE_SPACE = frozenset(
    [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    + list(range(0x2000, 0x200B))
)
# ``CharacterSet.whitespacesAndNewlines`` is Unicode category Z*, U+0009,
# U+000A-U+000D, U+0085, and -- from an older Unicode edition that Foundation
# still honours -- U+200B ZERO WIDTH SPACE.
_WHITESPACE_AND_NEWLINES = frozenset([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x200B])
# Foundation's built-in ``alphanumerics`` bitmap predates these Tangut blocks and
# still reports them as non-alphanumeric, so the mirror reproduces the omission.
_FOUNDATION_ALPHANUMERIC_GAPS = ((0x17000, 0x187F7), (0x18D00, 0x18D08))

CATEGORIES = ("correction", "punctuation", "capitalization", "filler", "repetition", "vocabulary")
# ``CleanupEditPlanValidator`` rejects a model-authored ``correction``: Explicit
# Corrections are reserved deterministic edits produced outside the model.
MODEL_CATEGORIES = tuple(category for category in CATEGORIES if category != "correction")
FILLER_WORDS = frozenset(["ah", "er", "erm", "hmm", "like", "uh", "um"])

# Mirrors ``CleanupPrompt.stopMarker``.
STOP_MARKER = "<END_PLAN>"

# Mirrors ``CleanupConfiguration``'s defaults. The change budget is
# ``max(8, ceil(characterCount * maximumChangedProportion))``.
DEFAULT_CONFIGURATION = {
    "maximumEdits": 8,
    "maximumChangedProportion": 0.35,
    "maximumReplacementCharacters": 64,
}

DEFAULT_TARGET_CONTEXT = {
    "applicationIdentifier": "com.example.editor",
    "applicationCategory": "textEditor",
    "textBeforeCursor": "",
    "textAfterCursor": "",
    "selectedText": None,
}


class PlanError(ValueError):
    """Raised when a value is not a well-formed Cleanup Edit Plan."""


class Span:
    """Mirrors ``TranscriptSpan``: an ordinal index plus a UTF-16 range."""

    __slots__ = ("index", "text", "start", "end")

    def __init__(self, index, text, start, end):
        self.index = index
        self.text = text
        self.start = start
        self.end = end

    def __repr__(self):
        return f"Span({self.index}, {self.text!r}, {self.start}, {self.end})"


# --------------------------------------------------------------------------
# Grapheme clustering
# --------------------------------------------------------------------------

_ZWJ = "\u200d"  # zero width joiner
_EXTEND_RANGES = (
    (0x200C, 0x200C),  # ZWNJ is Grapheme_Cluster_Break=Extend
    (0xFE00, 0xFE0F),  # variation selectors
    (0x1F3FB, 0x1F3FF),  # emoji modifiers (skin tones)
    (0xE0020, 0xE007F),  # tag characters
    (0xE0100, 0xE01EF),  # variation selectors supplement
)
# UAX #29 lists these spacing marks as Grapheme_Cluster_Break=Other even though
# their general category is Mc, and adds two Other_Letters that do combine.
_SPACING_MARK_EXCLUSIONS = frozenset(
    [0x102B, 0x102C, 0x1038, 0x1083, 0x108F, 0x1A61, 0x1A63, 0x1A64, 0xAA7B, 0xAA7D,
     0x11720, 0x11721]
    + list(range(0x1062, 0x1065))
    + list(range(0x1067, 0x106E))
    + list(range(0x1087, 0x108D))
    + list(range(0x109A, 0x109D))
)
_SPACING_MARK_ADDITIONS = frozenset([0x0E33, 0x0EB3])


def _is_extend(character):
    """Grapheme_Cluster_Break in {Extend, SpacingMark}: attaches to the cluster."""
    code = ord(character)
    if code in _SPACING_MARK_ADDITIONS:
        return True
    category = unicodedata.category(character)
    if category in ("Mn", "Me"):
        return True
    if category == "Mc":
        return code not in _SPACING_MARK_EXCLUSIONS
    return any(low <= code <= high for low, high in _EXTEND_RANGES)


def _is_regional_indicator(character):
    return 0x1F1E6 <= ord(character) <= 0x1F1FF


# ``Grapheme_Cluster_Break=Prepend`` in full: Arabic and Syriac marks plus the
# Indic cluster-initial letters.
_PREPEND = frozenset(
    list(range(0x0600, 0x0606))
    + [0x06DD, 0x070F, 0x0890, 0x0891, 0x08E2, 0x0D4E, 0x110BD, 0x110CD]
    + [0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11D46, 0x11F02]
    + list(range(0x11A84, 0x11A8A))
)


def _stands_alone(character):
    """``Grapheme_Cluster_Break`` in {Control, CR, LF}: never joined to anything.

    Rules GB4 and GB5 keep these on their own, so a control, format, line or
    paragraph separator never absorbs a following combining mark the way an
    ordinary base character does.
    """
    if ord(character) in _PREPEND or character == _ZWJ or _is_extend(character):
        return False
    return unicodedata.category(character) in ("Cc", "Cf", "Zl", "Zp")


def _is_pictographic(character):
    """Approximates ``\\p{Extended_Pictographic}`` for grapheme rule GB11."""
    code = ord(character)
    if code in (0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299):
        return True
    return any(
        low <= code <= high
        for low, high in ((0x2190, 0x2BFF), (0x1F000, 0x1FAFF), (0xFE0F, 0xFE0F))
    )


def _cluster_end(text, index):
    """Returns the end index of the extended grapheme cluster starting at ``index``."""
    length = len(text)
    first = text[index]
    end = index + 1
    if first == "\r" and end < length and text[end] == "\n":  # GB3
        return end + 1
    if _stands_alone(first):  # GB4, GB5
        return end
    if ord(first) in _PREPEND and end < length and not _stands_alone(text[end]):  # GB9b
        return _cluster_end(text, end)
    if _is_regional_indicator(first) and end < length and _is_regional_indicator(text[end]):
        end += 1  # GB12, GB13
    while end < length:
        character = text[end]
        if _is_extend(character):  # GB9, GB9a
            end += 1
        elif character == _ZWJ:
            # GB9 always attaches the ZWJ itself; GB11 additionally attaches a
            # following pictograph when the cluster started with one.
            end += 1
            if end < length and _is_pictographic(text[end]) and _is_pictographic(first):
                end += 1
        else:
            break
    return end


def graphemes(text):
    """Splits ``text`` into extended grapheme clusters, as ``Array(String)`` does."""
    clusters = []
    index = 0
    while index < len(text):
        end = _cluster_end(text, index)
        clusters.append(text[index:end])
        index = end
    return clusters


def utf16_width(text):
    return sum(2 if ord(character) > 0xFFFF else 1 for character in text)


def _utf16_index_map(text):
    """Maps a UTF-16 offset to the Python string index that starts there."""
    mapping = {}
    offset = 0
    for index, character in enumerate(text):
        mapping[offset] = index
        offset += 2 if ord(character) > 0xFFFF else 1
    mapping[offset] = len(text)
    return mapping


# --------------------------------------------------------------------------
# Tokenizer
# --------------------------------------------------------------------------


def is_alphanumeric(character):
    """Mirrors ``CharacterSet.alphanumerics.contains``.

    The set is Unicode categories L*, M* and N* (so it already subsumes
    ``CharacterSet.nonBaseCharacters``), minus the two Tangut blocks that
    Foundation's built-in bitmap still omits.
    """
    if any(low <= ord(character) <= high for low, high in _FOUNDATION_ALPHANUMERIC_GAPS):
        return False
    return unicodedata.category(character)[0] in ("L", "M", "N")


def _is_word_cluster(cluster):
    return bool(cluster) and all(is_alphanumeric(character) for character in cluster)


def _is_whitespace_cluster(cluster):
    # ``Character.isWhitespace`` reads the White_Space property of the cluster's
    # first scalar, so "U+00A0 U+0301" counts as whitespace.
    return bool(cluster) and ord(cluster[0]) in WHITE_SPACE


def _all_whitespace(text):
    return all(_is_whitespace_cluster(cluster) for cluster in graphemes(text))


def unmirrored_characters(text):
    """Code points this mirror cannot classify the way Foundation would.

    Python's Unicode tables trail Foundation's, so a code point that is
    unassigned here may be a letter there and would cluster differently. Text
    containing one is rejected rather than silently mis-tokenized.
    """
    return sorted(
        {
            character
            for character in text
            if unicodedata.category(character) == "Cn" or ord(character) == 0x11A3A
        }
    )


def tokenize(source):
    """Mirrors ``StableTranscript.tokenize``.

    Words are runs of L/M/N clusters, optionally joined by an apostrophe that has
    a word character on both sides. Every other non-whitespace cluster becomes its
    own one-cluster span. Whitespace ends a word and produces no span.
    """
    clusters = graphemes(source)
    spans = []
    word = ""
    word_start = 0
    offset = 0
    for position, cluster in enumerate(clusters):
        width = utf16_width(cluster)
        is_apostrophe = cluster in ("'", "\u2019")  # ASCII and typographic apostrophe
        joins_word = (
            is_apostrophe
            and word != ""
            and position + 1 < len(clusters)
            and _is_word_cluster(clusters[position + 1])
        )
        if _is_word_cluster(cluster) or joins_word:
            if word == "":
                word_start = offset
            word += cluster
        else:
            if word:
                spans.append(Span(len(spans), word, word_start, offset))
                word = ""
            if not _is_whitespace_cluster(cluster):
                spans.append(Span(len(spans), cluster, offset, offset + width))
        offset += width
    if word:
        spans.append(Span(len(spans), word, word_start, offset))
    return spans


# Taken from the Swift tokenizer itself. The first entry is the exact vector
# asserted by Packages/Cleanup/Tests/CleanupTests/StableTranscriptTests.swift; the
# rest pin one grapheme or word rule each, so a regression names its own cause.
MIRROR_VECTORS = (
    ("\U0001f469\U0001f3fd\u200d\U0001f4bb caf\u00e9 CR.",
     ["\U0001f469\U0001f3fd\u200d\U0001f4bb", "caf\u00e9", "CR", "."]),
    ("don't stop", ["don't", "stop"]),
    ("hi 'quoted' word", ["hi", "'", "quoted", "'", "word"]),
    ("visit https://example.test/a?x=1",
     ["visit", "https", ":", "/", "/", "example", ".", "test", "/", "a", "?", "x", "=", "1"]),
    ("cafe\u0301 3.5 GB", ["cafe\u0301", "3", ".", "5", "GB"]),
    ("a  b\u00a0c", ["a", "b", "c"]),
    # A control never absorbs a following mark; the mark then joins the word
    # after it. Zero width space is a control here too.
    ("hello\u0007world", ["hello", "\u0007", "world"]),
    ("a\u0007\u0301b c", ["a", "\u0007", "\u0301b", "c"]),
    ("approve\u200bthe change", ["approve", "\u200b", "the", "change"]),
    ("x\u200b\u093fy", ["x", "\u200b", "\u093fy"]),
    # Whitespace is decided by the cluster's first scalar, so marks ride along.
    ("one\u00a0\u0301\u0308two", ["one", "two"]),
    ("one\r\ntwo", ["one", "two"]),
    # Grapheme_Cluster_Break tables: the SpacingMark addition and exclusion
    # lists, Prepend, tag characters, regional indicator pairs, and keycaps.
    ("=\u0e33 ok", ["=\u0e33", "ok"]),
    ("=\u1087 ok", ["=", "\u1087", "ok"]),
    ("\u0d4e= ok", ["\u0d4e=", "ok"]),
    ("z\U000e0061 ok", ["z\U000e0061", "ok"]),
    ("\U0001f1fa\U0001f1f8 flag", ["\U0001f1fa\U0001f1f8", "flag"]),
    ("1\ufe0f\u20e3 done", ["1\ufe0f\u20e3", "done"]),
)


def mirror_vector_failures():
    """Returns a description of every tokenizer vector that no longer matches."""
    failures = []
    for source, expected in MIRROR_VECTORS:
        spans = tokenize(source)
        actual = [span.text for span in spans]
        if actual != expected:
            failures.append(f"{source!r}: expected {expected!r}, produced {actual!r}")
            continue
        index_of = _utf16_index_map(source)
        for span in spans:
            if source[index_of[span.start]:index_of[span.end]] != span.text:
                failures.append(
                    f"{source!r}: span {span.index} range does not address its own text"
                )
    return failures


# --------------------------------------------------------------------------
# Wire schema
# --------------------------------------------------------------------------


def _is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def parse_plan(value):
    """Mirrors the structural gate in ``BoundedEditPlanParser.decode``.

    Accepts only ``{"v":1,"e":[{"s":int,"e":int,"r":str,"c":category}]}`` with no
    extra, missing, or misspelled keys, and returns the edit list.
    """
    if not isinstance(value, dict) or set(value) != {"v", "e"}:
        raise PlanError("plan object must have exactly the keys v and e")
    if not _is_integer(value["v"]):
        raise PlanError("plan version must be an integer")
    if value["v"] != 1:
        raise PlanError("unsupported plan version")
    raw_edits = value["e"]
    if not isinstance(raw_edits, list):
        raise PlanError("plan edits must be a list")
    edits = []
    for raw_edit in raw_edits:
        if not isinstance(raw_edit, dict) or set(raw_edit) != {"s", "e", "r", "c"}:
            raise PlanError("edit object must have exactly the keys s, e, r and c")
        if not _is_integer(raw_edit["s"]) or not _is_integer(raw_edit["e"]):
            raise PlanError("edit span bounds must be integers")
        if not isinstance(raw_edit["r"], str):
            raise PlanError("edit replacement must be a string")
        if raw_edit["c"] not in CATEGORIES:
            raise PlanError(f"unknown edit category: {raw_edit['c']!r}")
        edits.append(
            {"s": raw_edit["s"], "e": raw_edit["e"], "r": raw_edit["r"], "c": raw_edit["c"]}
        )
    return edits


def plan_document(edits):
    """Builds the compact wire document, with the key order the prompt shows."""
    return {
        "v": 1,
        "e": [{"s": edit["s"], "e": edit["e"], "r": edit["r"], "c": edit["c"]} for edit in edits],
    }


# --------------------------------------------------------------------------
# Applier
# --------------------------------------------------------------------------


def edit_order(edit):
    return (edit["s"], edit["e"])


def _source_offsets(edit, spans, total_units):
    start, end = edit["s"], edit["e"]
    if start < 0 or end < start or end > len(spans):
        return None
    if start == end:
        offset = total_units if start == len(spans) else spans[start].start
        return offset, offset
    return spans[start].start, spans[end - 1].end


def _rtrim_whitespace(text):
    """Drops the trailing whitespace characters, as ``lastIndex(where:)`` does."""
    clusters = graphemes(text)
    end = len(clusters)
    while end > 0 and _is_whitespace_cluster(clusters[end - 1]):
        end -= 1
    return "".join(clusters[:end])


def apply_edits(edits, source, spans=None):
    """Mirrors ``CleanupEditApplier.apply``, including its fail-safe returns.

    Edits must already be sorted; a malformed or out-of-order plan yields the
    untouched ``source``, exactly as the Swift applier does.
    """
    if not edits:
        return source
    spans = tokenize(source) if spans is None else spans
    index_of = _utf16_index_map(source)
    total_units = utf16_width(source)

    def text(lower, upper):
        return source[index_of[lower]:index_of[upper]]

    pieces = []
    cursor = 0
    rendered_edits = []
    for edit in edits:
        previous = rendered_edits[-1] if rendered_edits else None
        if (previous and previous["r"] == edit["r"] == "" and previous["s"] < previous["e"]
                and edit["s"] < edit["e"] and previous["e"] == edit["s"]):
            rendered_edits[-1] = dict(previous, e=edit["e"])
        else:
            rendered_edits.append(edit)
    for index, edit in enumerate(rendered_edits):
        offsets = _source_offsets(edit, spans, total_units)
        if offsets is None:
            return source
        lower, upper = offsets
        if edit["r"] == "" and lower < upper:
            # Trim preceding whitespace at the end or before closing punctuation.
            trim_before = edit["e"] == len(spans)
            if edit["e"] < len(spans):
                following = rendered_edits[index + 1] if index + 1 < len(rendered_edits) else None
                boundary = following["r"] if following and following["s"] == edit["e"] else spans[edit["e"]].text
                first = next(iter(graphemes(boundary)), "")
                trim_before = first in (".", ",", ";", ":", "!", "?", "…", ")", "]", "}")
                following = spans[edit["e"]].start
                if _all_whitespace(text(upper, following)):
                    upper = following
            if trim_before and lower > cursor:
                trimmed = _rtrim_whitespace(text(cursor, lower))
                lower = cursor + utf16_width(trimmed)
        if lower < cursor:
            return source
        pieces.append(text(cursor, lower))
        pieces.append(edit["r"])
        cursor = upper
    pieces.append(text(cursor, total_units))
    return "".join(pieces)


# --------------------------------------------------------------------------
# Validation mirrors
# --------------------------------------------------------------------------


def bounds_violation(edits, span_count):
    """Mirrors the invalidBounds / unorderedOrOverlapping gate in the validator."""
    previous_end = 0
    previous_insertion = False
    for position, edit in enumerate(edits):
        start, end = edit["s"], edit["e"]
        if start < 0 or end < start or end > span_count:
            return "invalidBounds"
        insertion = start == end
        if position > 0 and (
            start < previous_end or (insertion and previous_insertion and start == previous_end)
        ):
            return "unorderedOrOverlapping"
        previous_end = end
        previous_insertion = insertion
    return None


def source_text(edit, spans, source):
    if edit["s"] >= edit["e"]:
        return ""
    index_of = _utf16_index_map(source)
    return source[index_of[spans[edit["s"]].start]:index_of[spans[edit["e"] - 1].end]]


def word_list(text):
    """Mirrors ``CleanupEditPlanValidator.wordList``.

    Lowercased spans that carry at least one alphanumeric scalar, in transcript
    order. Punctuation-only spans drop out.
    """
    return [
        span.text.lower()
        for span in tokenize(text)
        if any(is_alphanumeric(character) for character in span.text)
    ]


def _is_punctuation_or_whitespace(text):
    """Mirrors ``punctuationCharacters`` union ``whitespacesAndNewlines``."""
    return all(
        unicodedata.category(character)[0] in ("P", "Z")
        or ord(character) in _WHITESPACE_AND_NEWLINES
        for character in text
    )


def _normalized_vocabulary_text(text):
    return "".join(character for character in text.lower() if is_alphanumeric(character))


def category_violation(edit, spans, source, vocabulary_terms, model_authored=True):
    """Mirrors ``CleanupEditPlanValidator.isCategorySafe`` and its no-op check."""
    text = source_text(edit, spans, source)
    if text == edit["r"]:
        return "edit changes nothing"
    category = edit["c"]
    if category == "correction":
        if model_authored:
            return "correction is a reserved deterministic category"
        return None
    symbols = lambda value: "".join(cluster for cluster in graphemes(value)
                                   if any(unicodedata.category(c).startswith("S") for c in cluster))
    if symbols(text) != symbols(edit["r"]):
        return "mechanical edit changes symbols"
    if category == "punctuation":
        if not (_is_punctuation_or_whitespace(edit["r"]) and _is_punctuation_or_whitespace(text)):
            return "punctuation edit touches non-punctuation"
        return None
    if category == "capitalization":
        if not text or text.lower() != edit["r"].lower():
            return "capitalization edit changes letters"
        return None
    if category == "filler":
        words = set(word_list(text))
        if edit["r"] != "" or not words or not words <= FILLER_WORDS:
            return "filler edit removes non-filler"
        return None
    if category == "repetition":
        words = word_list(text)
        if edit["r"] != "" or edit["s"] >= edit["e"] or len(words) != 1:
            return "repetition edit is not a single deleted word"
        before = spans[edit["s"] - 1].text.lower() if edit["s"] > 0 else None
        after = spans[edit["e"]].text.lower() if edit["e"] < len(spans) else None
        if words[0] not in (before, after):
            return "repetition edit has no adjacent duplicate"
        return None
    if category == "vocabulary":
        if not text or edit["r"] not in vocabulary_terms:
            return "vocabulary edit does not name a known term"
        if _normalized_vocabulary_text(text) != _normalized_vocabulary_text(edit["r"]):
            return "vocabulary edit changes more than spelling"
        return None
    return f"unknown category: {category!r}"


def character_count(text):
    """Mirrors Swift's ``String.count``, which counts grapheme clusters."""
    return len(graphemes(text))


def _is_unsafe_scalar(character):
    """Mirrors the validator's ``isSafe`` rejection of unusable general categories."""
    return unicodedata.category(character) in ("Cc", "Cf", "Zl", "Zp", "Cs", "Co", "Cn")


def _conflicts_with_reserved(edit, reserved):
    """Mirrors ``CleanupEditPlanValidator.conflicts``."""
    if edit["s"] == edit["e"]:
        return reserved["s"] < edit["s"] < reserved["e"]
    return edit["s"] < reserved["e"] and reserved["s"] < edit["e"]


def copies_context(replacement, source, target_context, vocabulary_terms):
    """Mirrors ``CleanupEditPlanValidator.copiesContext``."""
    context = target_context or {}
    joined = " ".join(
        [
            context.get("textBeforeCursor", ""),
            context.get("textAfterCursor", ""),
            context.get("selectedText") or "",
        ]
    )
    context_words = set(word_list(joined))
    source_words = set(word_list(source))
    vocabulary_words = {word for term in vocabulary_terms for word in word_list(term)}
    return any(
        len(word) >= 4
        and word in context_words
        and word not in source_words
        and word not in vocabulary_words
        for word in word_list(replacement)
    )


def _removes_only_filler(edits, spans):
    """Mirrors ``CleanupEditPlanValidator.removesOnlyFiller``."""
    return any(edit["c"] == "filler" for edit in edits) and all(
        edit["r"] == ""
        and edit["c"] in ("filler", "punctuation")
        and all(
            span.text.lower() in FILLER_WORDS or _is_punctuation_or_whitespace(span.text)
            for span in spans[edit["s"]:edit["e"]]
        )
        for edit in edits
    )


def _trimmed_is_empty(text):
    """Mirrors ``trimmingCharacters(in: .whitespacesAndNewlines).isEmpty``."""
    return all(
        unicodedata.category(character)[0] == "Z" or ord(character) in _WHITESPACE_AND_NEWLINES
        for character in text
    )


# Mirrors CleanupEditPlanValidator.literalPattern; preserve URL/numeric spelling.
PROTECTED_LITERALS = re.compile(
    r"\b(?:[A-Za-z][A-Za-z0-9+.-]*://|[mM][aA][iI][lL][tT][oO]:|[wW]{3}\.)\S+"
    r"|\b(?:[\w-]+\.)+[\w-]+(?::[0-9]+)?(?:[/?#]\S*)?"
    r"|(?:[+−-][ \t]*)?(?:\d+(?:[.,:/٫٬-]\d+)*|[.٫]\d+)(?:[eE][+−-]?\d+)?"
    r"|[%‰٪]"
)


def plan_violation(
    edits,
    source,
    vocabulary_terms=(),
    reserved_edits=(),
    target_context=None,
    model_authored=True,
    configuration=DEFAULT_CONFIGURATION,
):
    """Mirrors ``CleanupEditPlanValidator.validate``: the first rejection, or ``None``.

    Every rule the validator applies is checked here, in the validator's own
    order, so a plan this function accepts is one the runtime accepts. The return
    value starts with the Swift error case name so callers can compare it against
    ``CleanupEditValidationError`` directly.
    """
    spans = tokenize(source)
    if len(edits) > configuration["maximumEdits"]:
        return f"tooManyEdits ({len(edits)} > {configuration['maximumEdits']})"
    if any(_is_unsafe_scalar(character) for character in source):
        return "unsafeUnicode (raw transcript)"

    previous_end = 0
    previous_insertion = False
    changed_characters = 0
    for position, edit in enumerate(edits):
        start, end = edit["s"], edit["e"]
        if start < 0 or end < start or end > len(spans):
            return f"invalidBounds (edit {position} spans {start}..{end} of {len(spans)})"
        insertion = start == end
        if position > 0 and (
            start < previous_end or (insertion and previous_insertion and start == previous_end)
        ):
            return f"unorderedOrOverlapping (edit {position} starts at {start})"
        previous_end = end
        previous_insertion = insertion

        if any(_conflicts_with_reserved(edit, reserved) for reserved in reserved_edits):
            return f"reservedSpan (edit {position} touches a reserved Explicit Correction)"
        replacement_length = character_count(edit["r"])
        if replacement_length > configuration["maximumReplacementCharacters"]:
            return (
                f"replacementTooLarge (edit {position} replacement is {replacement_length} "
                f"characters)"
            )
        if any(_is_unsafe_scalar(character) for character in edit["r"]):
            return f"unsafeUnicode (edit {position} replacement)"

        text = source_text(edit, spans, source)
        if text == edit["r"]:
            return f"unsafeCategory (edit {position} changes nothing)"
        if copies_context(edit["r"], source, target_context, vocabulary_terms):
            return f"copiedTargetContext (edit {position} replacement)"
        detail = category_violation(edit, spans, source, vocabulary_terms, model_authored)
        if detail:
            return f"unsafeCategory (edit {position}: {detail})"

        changed_characters += max(character_count(text), replacement_length)

    allowed = max(
        8,
        math.ceil(character_count(source) * configuration["maximumChangedProportion"]),
    )
    if changed_characters > allowed:
        return f"excessiveChange ({changed_characters} changed characters, budget {allowed})"

    merged = sorted(list(reserved_edits) + list(edits), key=edit_order)
    output = apply_edits(merged, source, spans)
    authoritative = list(reserved_edits)
    if not model_authored:
        authoritative += [edit for edit in edits if edit["c"] == "correction"]
    baseline = apply_edits(sorted(authoritative, key=edit_order), source, spans)
    if PROTECTED_LITERALS.findall(baseline) != PROTECTED_LITERALS.findall(output):
        return "unsafeCategory (mechanical edit changes a URL or numeric literal)"
    if _trimmed_is_empty(output) and not _removes_only_filler(
        merged, spans
    ):
        return "blankOutput (the plan empties the transcript)"
    return None


def change_budget(source, configuration=DEFAULT_CONFIGURATION):
    """The validator's ``allowedChanges`` for a Raw Transcript, for authoring fixtures."""
    return max(8, math.ceil(character_count(source) * configuration["maximumChangedProportion"]))


def changed_characters(edits, source):
    """The validator's ``changedCharacters`` total for a plan."""
    spans = tokenize(source)
    return sum(
        max(character_count(source_text(edit, spans, source)), character_count(edit["r"]))
        for edit in edits
    )


def resolve(source, edits, reserved_edits=()):
    """Applies reserved Explicit Corrections and model edits together."""
    merged = sorted(list(reserved_edits) + list(edits), key=edit_order)
    return apply_edits(merged, source)
