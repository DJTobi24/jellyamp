#!/usr/bin/env python3
r"""Check that every localizable string in the iOS app has a German translation.

Xcode normally fills ``Localizable.xcstrings`` on every build
(``SWIFT_EMIT_LOC_STRINGS``). This script does the same job on Linux, where
the catalog is maintained by hand: it finds the string keys the app code
uses, converts Swift interpolation into the format keys Xcode generates, and
compares them with ``ios/Jellyamp/Resources/Localizable.xcstrings``.

Usage::

    python3 scripts/check-localization.py            # check; exit 1 on errors
    python3 scripts/check-localization.py --keys     # print every key + where
    python3 scripts/check-localization.py --strays   # literals NOT treated as
                                                     # keys (review aid)

Reported as errors (exit 1):

* keys used in code that are missing from the catalog or lack a ``de``
  translation in state ``translated``,
* translations whose format specifiers differ from their key's (type or
  argument position), in any plural variation,
* interpolations whose type the script cannot name (see below),
* a literal that shares a ternary with a non-literal branch in a localized
  position (``Text(flag ? "Off" : name)``): the expression is a ``String``
  then and the literal is shown untranslated,
* App Shortcut phrases without a German entry in
  ``de.lproj/AppShortcuts.strings``, or German phrases whose ``${…}``
  placeholders differ from the English phrase,
* ``InfoPlist.xcstrings`` entries without English or German, and usage
  descriptions in ``ios/project.yml`` that are missing from it.

Reported as warnings (exit 0): catalog keys and App Shortcut phrases no code
uses any more (stale); a missing ``AppShortcuts.strings`` (phrases then stay
English-only).

What is recognised as a key
---------------------------
A string literal is a key when it is

* an argument of a known SwiftUI / App Intents API that takes
  ``LocalizedStringKey`` / ``LocalizedStringResource`` (table ``API_RULES``),
  including the branches of ``cond ? "A" : "B"`` in that argument position
  (but not ``x ?? "A"``: that expression has the type of ``x``),
* the argument of ``String(localized:)``, ``LocalizedStringKey(_:)``,
  ``LocalizedStringResource(_:)``, ``NSLocalizedString(_:)``,
* an argument of a function, initializer or memberwise ``struct`` initializer
  *declared in the app* whose parameter is typed ``LocalizedStringKey`` /
  ``LocalizedStringResource`` (discovered automatically by name and label),
* assigned to, or returned from, a declaration typed ``LocalizedStringKey`` /
  ``LocalizedStringResource`` (``static let title: LocalizedStringResource =
  "…"``, computed properties and functions with that result type), or
  assigned to a ``TypeDisplayRepresentation`` / ``DisplayRepresentation``
  (also as values of a typed dictionary such as
  ``caseDisplayRepresentations``).

Key format: ``\(x)`` becomes ``%lld`` / ``%@`` / ``%lf`` by the type of
``x``; a ``%`` typed in an interpolated literal becomes ``%%``; App Intents
parameter references ``\(\.$name)`` become ``${name}``. Keys keep plain
specifiers (``%@ of %@``) because that is what the app looks up at run time;
translations number them (``%1$@ von %2$@``). Keys without any letter
(``"\(count)"``, ``"·"``) are ignored.

What this script cannot detect — read before trusting a green run
-----------------------------------------------------------------
* It is a lexer plus name matching, not a type checker. A ``String`` *value*
  handed to ``Text(_:)`` (``Text(title)``) is shown verbatim by SwiftUI and
  never localized; the script cannot see that. Such strings must be produced
  by ``String(localized:)`` or typed ``LocalizedStringKey`` at their origin.
  ``--strays`` lists the literals that were not classified as keys and look
  like prose, as a review aid; it is a heuristic, not a proof.
* Interpolation types are not inferred. Xcode writes ``%lld`` for integers,
  ``%lf`` for ``Double``, ``%@`` for strings/objects. The script decides by
  the rules in ``specifier_for`` and the explicit table
  ``INTERPOLATION_TYPES`` below, which was filled in by reading the code. An
  expression matching neither is an error, so new interpolations must be
  classified by a human. If a variable's type changes (say ``Int`` to
  ``String``) while its name stays, the key the app looks up at run time
  changes and the script will not notice.
* Calls are matched by callee name and argument label only. Two unrelated
  functions with the same name are not told apart, and literals that reach a
  localizing API through a wrapper the script does not know (a generic
  helper, a closure, a stored ``let x = "…"`` typed by inference) are
  missed. ``Text(verbatim:)`` and ``String`` parameters are correctly left
  out, but a custom view whose parameter *should* be a ``LocalizedStringKey``
  and is a ``String`` instead looks exactly the same to the script.
* The ``%%`` rule and the ``${name}`` form of intent summaries follow what
  Xcode 15/16 put into catalogs; they could not be run against Xcode here.
* Strings in ``ios/Packages`` are out of scope: the packages have no resource
  bundles. Package text that reaches the UI is supplied by the app shell
  (see ``ios/Jellyamp/Localization/CoreLocalization.swift``).
* It does not judge translation quality, truncation, or plural correctness
  beyond "the same specifiers are present".
* Whether Xcode's own extraction would list exactly the same keys is
  untested here (no macOS); differences would show up as "stale" or "new"
  entries in Xcode's catalog editor, not as run-time failures.

Glossary (keep new German strings consistent; see docs/LOCALIZATION.md)
-----------------------------------------------------------------------
Library → Bibliothek · Song/Track → Titel · Album(s) → Album/Alben ·
Artist → Interpret · Playlist → Playlist · Genre → Genre · Queue →
Warteschlange · Up Next → Als Nächstes · Play → Wiedergabe · Shuffle →
Zufällig · Repeat → Wiederholen · Lyrics → Songtext · Sleep Timer →
Sleep-Timer · Download (verb) → Laden · Downloads → Downloads · Downloaded
→ Geladen · Liked Songs → Lieblingstitel · Favorite → Favorit · Saved
Albums → Gespeicherte Alben · Recently Added → Zuletzt hinzugefügt ·
Recently Played → Zuletzt gehört · Home → Start · Search → Suchen ·
Settings → Einstellungen · Sign In/Out → Anmelden / Abmelden · Account →
Account · Station → Sender · Radio → Radio · Mix → Mix (pl. Mixe) ·
Instant Mix → Sofort-Mix · Crossfade → Überblenden · Loudness Leveling →
Lautstärkeanpassung · Scrobbling → Scrobbeln · listen (scrobble) →
Scrobble · Cellular → Mobile Daten · Wi-Fi → WLAN · Save (button) →
Sichern · sonic server → Sonic-Server · API key → API-Schlüssel.
Address the user as "du". Product names stay as they are: Jellyamp,
Jellyfin, jellyamp-server, Quick Connect, Last.fm, ListenBrainz, CarPlay,
AirPlay, Sonic Adventure, Smart Sync.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_SOURCES = ROOT / "ios" / "Jellyamp"
RESOURCES = APP_SOURCES / "Resources"
CATALOG = RESOURCES / "Localizable.xcstrings"
INFOPLIST_CATALOG = RESOURCES / "InfoPlist.xcstrings"
SHORTCUT_STRINGS = RESOURCES / "de.lproj" / "AppShortcuts.strings"
PROJECT_YML = ROOT / "ios" / "project.yml"
LANGUAGE = "de"

# --------------------------------------------------------------------------
# Which call arguments are localized.
#
# callee name -> set of argument selectors. A selector is an argument label
# ("prompt") or a position (0 = first argument) for unlabeled arguments.
# --------------------------------------------------------------------------

API_RULES: dict[str, set] = {
    # SwiftUI views
    "Text": {0},
    "Label": {0},
    "Button": {0},
    "Toggle": {0},
    "Section": {0},
    "NavigationLink": {0},
    "TextField": {0, "prompt"},
    "SecureField": {0, "prompt"},
    "TextEditor": set(),
    "Picker": {0},
    "Stepper": {0},
    "Slider": set(),
    "DatePicker": {0},
    "ColorPicker": {0},
    "LabeledContent": {0},
    "Menu": {0},
    "Link": {0},
    "ShareLink": {0},
    "ProgressView": {0},
    "Gauge": set(),
    "DisclosureGroup": {0},
    "GroupBox": {0},
    "ControlGroup": {0},
    "Tab": {0},
    "ContentUnavailableView": {0, "description"},
    "EditButton": set(),
    # SwiftUI modifiers
    "navigationTitle": {0},
    "navigationBarTitle": {0},
    "navigationSubtitle": {0},
    "accessibilityLabel": {0},
    "accessibilityHint": {0},
    "accessibilityValue": {0},
    "accessibilityInputLabels": {0},
    "accessibilityAction": {"named"},
    "accessibilityCustomContent": {0, 1},
    "alert": {0},
    "confirmationDialog": {0},
    "searchable": {"prompt"},
    "help": {0},
    "badge": {0},
    "tabItem": set(),
    # Foundation
    "String": {"localized"},
    "AttributedString": {"localized"},
    "LocalizedStringKey": {0},
    "LocalizedStringResource": {0},
    "NSLocalizedString": {0},
    # App Intents
    "IntentDescription": {0, "categoryName"},
    "IntentDialog": {0, "full", "supporting"},
    "DisplayRepresentation": {"title", "subtitle"},
    "TypeDisplayRepresentation": {"name"},
    "Parameter": {"title", "description"},
    "Property": {"title"},
    "AppShortcut": {"shortTitle"},
    "needsValueError": {0},
    "Summary": {0},  # ParameterSummary; parameters become ${name}
}

LOCALIZED_TYPES = ("LocalizedStringKey", "LocalizedStringResource")
# Types that are built from a localized string literal when assigned one.
LITERAL_TYPES = LOCALIZED_TYPES + ("TypeDisplayRepresentation", "DisplayRepresentation")

# --------------------------------------------------------------------------
# Interpolation types, determined by reading the code. Maps the exact source
# text of an interpolated expression to the specifier Xcode would generate.
# Checked after the generic rules in specifier_for().
# --------------------------------------------------------------------------

INT, TEXT = "%lld", "%@"

INTERPOLATION_TYPES: dict[str, str] = {
    # Int
    "Int(container.settings.crossfadeDuration)": INT,
    "Int(container.settings.sleepTimerFadeOut)": INT,
    "choice": INT,  # SonicAdventureView: ForEach over [Int]
    "complete": INT,  # DownloadsView: downloads.downloaded.count
    "total": INT,  # DownloadsView / TrackBrowser: counts
    "disc.disc": INT,  # DiscSection.disc
    "entries.count - visibleLimit": INT,
    "entry.track.indexNumber ?? number": INT,
    "number": INT,  # row / track numbers
    "minutes": INT,  # sleep timer and durations, always whole minutes
    "hours": INT,
    "seconds": INT,
    "httpStatus": INT,
    "status": INT,  # JellyfinError.serverError(status: Int), serverUnavailable(status: Int)
    "progress.complete": INT,  # DownloadIndex.Progress
    "progress.total": INT,
    "progress.tracksAnalyzed": INT,  # AnalysisProgressSummary
    "progress.tracksTotal": INT,
    "progress.percent": INT,
    "syncState.skippedForStorage": INT,  # SmartSyncState.skippedForStorage = 0
    "picked": INT,  # SageResult.Notice / SageFailure.nothingResolved(picked: Int)
    "found": INT,
    "requested": INT,
    "excess": INT,  # SonicSageModel.excessCharacters: Int?
    "remaining": INT,  # SagePrompt.remainingCharacters(for:) -> Int
    "SagePrompt.maxLength": INT,
    "Int(elapsed)": INT,
    "scan.tracksPending": INT,  # SonicScanStatus.tracksPending: Int
    # String
    "DownloadFormatting.bytes(bytes)": TEXT,
    "DownloadFormatting.bytes(downloads.totalBytes)": TEXT,
    "PlaybackTimeFormat.spoken(duration)": TEXT,
    "PlaybackTimeFormat.spoken(position)": TEXT,
    "PlaybackTimeFormat.spoken(remaining)": TEXT,
    "album": TEXT,  # Track.albumName
    "albumName": TEXT,
    "artist": TEXT,  # PlaybackSummary.subtitle
    "connectedVersion": TEXT,
    "decade": TEXT,  # years are passed as text, see CoreLocalization.swift
    "detail": TEXT,  # SageFailure.serverDetail
    "prompt": TEXT,  # SonicSageResultView.prompt
    "errorMessage": TEXT,
    "letter": TEXT,
    "minimum": TEXT,  # JellyfinConnectionError.serverTooOld(version: String, minimum: String)
    "version": TEXT,
    "name": TEXT,
    "playlistName": TEXT,
    "query": TEXT,
    "reason": TEXT,
    "resultsQuery": TEXT,
    "searchTerm": TEXT,
    "searchText": TEXT,
    "server.url.host ?? server.url.absoluteString": TEXT,
    "server.version": TEXT,  # DiscoveredServer.version: String
    "subtitleText": TEXT,
    "time": TEXT,  # Date.formatted(...)
    "title": TEXT,
    "track.artistName": TEXT,
}


class LocalizationError(Exception):
    pass


def specifier_for(expression: str, unknown: list[str]) -> str:
    """Format specifier Xcode generates for one ``\\(expression)``."""
    expr = expression.strip()
    spec = re.search(r',\s*specifier:\s*"([^"]+)"\s*$', expr)
    if spec:
        return spec.group(1)
    if re.search(r",\s*format:", expr):
        return "%@"
    if expr in INTERPOLATION_TYPES:
        return INTERPOLATION_TYPES[expr]
    if re.fullmatch(r"-?\d+", expr):
        return "%lld"
    # A string literal, a Text, or an explicit String(...) conversion.
    if expr.startswith(('"', "Text(", "String(")):
        return "%@"
    # Formatting calls produce String.
    if re.search(r"\.(formatted|description|localizedDescription|uppercased|"
                 r"lowercased|capitalized|joined)\s*(\(.*\))?$", expr, re.S):
        return "%@"
    if re.search(r"\.(name|title|displayName|localizedTitle)$", expr):
        return "%@"
    if re.search(r"\.count$", expr) or expr == "count":
        return "%lld"
    unknown.append(expr)
    return "%@"


# --------------------------------------------------------------------------
# Swift lexing: string literals (with interpolation) and a masked copy of
# the source in which comments and literal contents are blanked out.
# --------------------------------------------------------------------------


@dataclass
class Literal:
    start: int  # offset of the opening delimiter in its masked text
    end: int  # offset just past the closing delimiter
    parts: list  # str (text) or ("interp", expression)
    masked: str = ""  # the masked text this literal lives in
    line: int = 0
    nested: list = field(default_factory=list)  # literals inside interpolations

    @property
    def plain(self) -> bool:
        return all(isinstance(p, str) for p in self.parts)

    def text(self) -> str:
        return "".join(p if isinstance(p, str) else "\\(" + p[1] + ")"
                       for p in self.parts)


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'",
           "\\": "\\"}


def lex(src: str, base_line: int = 1) -> tuple[str, list[Literal]]:
    """Return (masked source, top-level string literals)."""
    out = list(src)
    literals: list[Literal] = []
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif src.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 8])):
            lit, j = read_literal(src, i)
            lit.line = base_line + src.count("\n", 0, i)
            # Keep the delimiters so context matching sees a literal here.
            blank(i, j)
            out[i] = '"'
            out[j - 1] = '"'
            literals.append(lit)
            i = j
        else:
            i += 1
    masked = "".join(out)
    for lit in literals:
        lit.masked = masked
    return masked, literals


def read_literal(src: str, i: int) -> tuple[Literal, int]:
    start = i
    hashes = 0
    while src[i] == "#":
        hashes += 1
        i += 1
    multiline = src.startswith('"""', i)
    quote = '"""' if multiline else '"'
    i += len(quote)
    closing = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    parts: list = []
    buf: list[str] = []
    nested: list[Literal] = []
    n = len(src)
    while i < n:
        if src.startswith(closing, i):
            i += len(closing)
            break
        if src.startswith(escape, i):
            j = i + len(escape)
            ch = src[j] if j < n else ""
            if ch == "(":
                depth, k = 1, j + 1
                while k < n and depth:
                    if src[k] == '"' or (src[k] == "#" and re.match(r'#+"', src[k:k + 8])):
                        _, k = read_literal(src, k)
                        continue
                    if src[k] == "(":
                        depth += 1
                    elif src[k] == ")":
                        depth -= 1
                    k += 1
                expression = src[j + 1:k - 1]
                if buf:
                    parts.append("".join(buf))
                    buf = []
                parts.append(("interp", expression))
                _, inner = lex(expression, 0)
                for lit in inner:
                    lit.line = src.count("\n", 0, start)  # fixed up by caller
                nested.extend(inner)
                i = k
            elif ch == "u" and src.startswith("{", j + 1):
                k = src.index("}", j)
                buf.append(chr(int(src[j + 2:k], 16)))
                i = k + 1
            elif ch == "\n" and multiline:
                i = j + 1  # line continuation
                # Swallow the next line's indentation marker; dedent handles it.
                buf.append("\x00")
            elif ch in ESCAPES:
                buf.append(ESCAPES[ch])
                i = j + 1
            else:
                buf.append(ch)
                i = j + 1
        else:
            buf.append(src[i])
            i += 1
    if buf:
        parts.append("".join(buf))
    if multiline:
        parts = dedent_multiline(parts)
    return Literal(start=start, end=i, parts=parts, nested=nested), i


def dedent_multiline(parts: list) -> list:
    """Apply Swift's multi-line literal rules (closing-delimiter indentation)."""
    marker = "\x01"
    joined = "".join(p if isinstance(p, str) else marker for p in parts)
    lines = joined.split("\n")
    indent = lines[-1] if lines[-1].strip() == "" else ""
    body = lines[1:-1]
    body = [ln[len(indent):] if ln.startswith(indent) else ln.lstrip() for ln in body]
    text = "\n".join(body)
    # "\<newline>" joins lines, dropping the following line's leading indent.
    text = re.sub("\x00" + r"\n?", "", text)
    result: list = []
    interps = [p for p in parts if not isinstance(p, str)]
    for k, chunk in enumerate(text.split(marker)):
        if chunk:
            result.append(chunk)
        if k < len(interps):
            result.append(interps[k])
    return result


# --------------------------------------------------------------------------
# Context: is this literal in a localized position?
# --------------------------------------------------------------------------

OPEN, CLOSE = "([{", ")]}"
PAIR = {")": "(", "]": "[", "}": "{"}


def enclosing_open(masked: str, pos: int) -> int:
    """Offset of the innermost unmatched opening bracket before pos, or -1."""
    depth = 0
    i = pos - 1
    while i >= 0:
        ch = masked[i]
        if ch in CLOSE:
            depth += 1
        elif ch in OPEN:
            if depth == 0:
                return i
            depth -= 1
        i -= 1
    return -1


def split_top_level(masked: str, start: int, end: int) -> list[int]:
    """Offsets of top-level commas in masked[start:end]."""
    commas, depth = [], 0
    for i in range(start, end):
        ch = masked[i]
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
        elif ch == "," and depth == 0:
            commas.append(i)
    return commas


CALLEE = re.compile(r"([A-Za-z_]\w*)\s*(?:<[^<>()]*>)?\s*$")
TERNARY_PREFIX = re.compile(r"^(?:[^,;{}]*(?<!\?)[?:])?\s*$", re.S)
DECL_HEADER = re.compile(r"\b(var|func|init|subscript)\b")
CONTROL_FLOW = re.compile(
    r"\s*(?:switch|if|else|for|while|do|guard|case|default|repeat|catch)\b")
LOCALIZED_RESULT = re.compile(
    r"(?:->|:)\s*(?:" + "|".join(LOCALIZED_TYPES) + r")\??\s*$")
LOCALIZED_ASSIGN = re.compile(
    r":\s*(?:" + "|".join(LITERAL_TYPES) + r")\??\s*=\s*(?:[^=;{}\n]*[?:]\s*)?$")
# `static var x: [Case: DisplayRepresentation] = [` / `[LocalizedStringKey] = [`
LOCALIZED_COLLECTION = re.compile(
    r":\s*\[(?:[^\[\]]*:\s*)?(?:" + "|".join(LITERAL_TYPES) + r")\]\s*=\s*$")


def localized_reason(lit: Literal, rules: dict[str, set]) -> str | None:
    """Why this literal is a localization key, or None if it is not."""
    masked = lit.masked
    pos = lit.start
    # 1. Call arguments, looking through grouping parentheses.
    while True:
        open_at = enclosing_open(masked, pos)
        if open_at >= 0 and masked[open_at] == "[":
            # Element (or dictionary value) of a typed collection literal.
            if LOCALIZED_COLLECTION.search(masked[max(0, open_at - 200):open_at]) and re.search(
                    r"[\[,:]\s*$", masked[open_at:pos]):
                return "localized collection"
            break
        if open_at < 0 or masked[open_at] != "(":
            break
        before = masked[:open_at]
        callee = CALLEE.search(before)
        if not callee or callee.group(1) in ("if", "while", "switch", "return",
                                             "in", "case", "guard"):
            # Grouping parenthesis: the group stands where the literal stood.
            between = masked[open_at + 1:pos]
            if not TERNARY_PREFIX.match(between):
                return None
            pos = open_at
            continue
        name = callee.group(1)
        commas = [c for c in split_top_level(masked, open_at + 1, pos)]
        arg_start = (commas[-1] + 1) if commas else open_at + 1
        argument = masked[arg_start:pos]
        label_match = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", argument)
        if label_match:
            selector: object = label_match.group(1)
            rest = argument[label_match.end():]
        else:
            selector = len(commas)
            rest = argument
        if not TERNARY_PREFIX.match(rest):
            return None
        if selector in rules.get(name, ()):
            where = f"{name}({selector if isinstance(selector, str) else '_'}:)"
            if rest.strip() and not ternary_is_all_literals(masked, arg_start, open_at):
                return MIXED + where
            return where
        return None
    # 2. Assignment to a localized-typed declaration.
    line_start = max(masked.rfind("\n", 0, pos), masked.rfind(";", 0, pos)) + 1
    statement = masked[max(0, pos - 400):pos]
    if LOCALIZED_ASSIGN.search(statement):
        return "localized declaration"
    # 3. Body of a computed property / function with a localized result type.
    scope = pos
    while True:
        open_at = enclosing_open(masked, scope)
        if open_at < 0:
            return None
        if masked[open_at] != "{":
            return None
        header_start = max(masked.rfind("}", 0, open_at),
                           masked.rfind("{", 0, open_at),
                           masked.rfind(";", 0, open_at)) + 1
        header = masked[header_start:open_at]
        last_line = header.strip().split("\n")[-1] if header.strip() else ""
        if CONTROL_FLOW.match(last_line):
            # `switch x {`, `if y {` …: look at the declaration around it.
            scope = open_at
            continue
        if DECL_HEADER.search(header):
            if LOCALIZED_RESULT.search(header):
                between = masked[line_start:pos]
                # Only bare results: `"x"`, `return "x"`, `case .a: "x"`,
                # ternaries — not arguments of some other call.
                if re.search(r"[(\[]\s*$", between):
                    return None
                return "localized result"
            return None
        scope = open_at


MIXED = "mixed ternary in "


def ternary_is_all_literals(masked: str, arg_start: int, open_at: int) -> bool:
    """True when every branch of the ternary argument is a string literal.

    `Text(flag ? "A" : "B")` is a LocalizedStringKey; one non-literal branch
    (`flag ? "A" : name`) makes the whole expression a String, which SwiftUI
    shows verbatim — the literal then silently stops being localized.
    """
    depth, end = 0, len(masked)
    for i in range(open_at + 1, len(masked)):
        ch = masked[i]
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            if depth == 0:
                end = i
                break
            depth -= 1
        elif ch == "," and depth == 0 and i > arg_start:
            end = i
            break
    argument = masked[arg_start:end]
    argument = re.sub(r"^\s*[A-Za-z_]\w*\s*:(?!:)", "", argument)
    question = argument.find("?")
    if question < 0:
        return True
    branches, depth, last = [], 0, question + 1
    for i in range(question + 1, len(argument)):
        ch = argument[i]
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            depth -= 1
        elif ch in "?:" and depth == 0:
            branches.append(argument[last:i])
            last = i + 1
    branches.append(argument[last:])
    # Conditions of chained ternaries (`a ? "x" : b ? "y" : "z"`) sit between
    # ":" and "?"; they are the pieces followed by "?", so only judge pieces
    # that are literals or parenthesised groups, and require at least the
    # first and last to be literals.
    def literal(piece: str) -> bool:
        piece = piece.strip()
        return bool(re.fullmatch(r'#*"[^"]*"#*', piece)) or piece.startswith("(")
    return literal(branches[0]) and literal(branches[-1])


# --------------------------------------------------------------------------
# Declarations in the app that take LocalizedStringKey / Resource.
# --------------------------------------------------------------------------

TYPE_DECL = re.compile(r"\b(struct|class|enum|actor|extension)\s+([A-Za-z_]\w*)")
FUNC_DECL = re.compile(r"\b(func\s+([A-Za-z_]\w*)|init)\s*(?:<[^>]*>)?\s*\(")
PARAM = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:([A-Za-z_]\w*)\s+)?([A-Za-z_]\w*)\s*:\s*"
    r"(?:" + "|".join(LOCALIZED_TYPES) + r")\??\s*(?:=.*)?$", re.S)
STORED = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate)\s+)?(?:let|var)\s+"
    r"([A-Za-z_]\w*)\s*:\s*(?:" + "|".join(LOCALIZED_TYPES) + r")\??\s*(=.*)?$")


def enclosing_type(masked: str, pos: int) -> str | None:
    scope = pos
    while True:
        open_at = enclosing_open(masked, scope)
        if open_at < 0:
            return None
        if masked[open_at] == "{":
            header_start = max(masked.rfind("}", 0, open_at),
                               masked.rfind("{", 0, open_at),
                               masked.rfind(";", 0, open_at)) + 1
            found = TYPE_DECL.search(masked[header_start:open_at])
            if found:
                return found.group(2)
        scope = open_at


def discover_rules(masked: str, rules: dict[str, set]) -> None:
    for found in FUNC_DECL.finditer(masked):
        open_at = found.end() - 1
        depth, close_at = 0, open_at
        for k in range(open_at, len(masked)):
            if masked[k] == "(":
                depth += 1
            elif masked[k] == ")":
                depth -= 1
                if depth == 0:
                    close_at = k
                    break
        name = found.group(2) or enclosing_type(masked, found.start())
        if not name:
            continue
        commas = split_top_level(masked, open_at + 1, close_at)
        bounds = [open_at] + commas + [close_at]
        for index in range(len(bounds) - 1):
            param = PARAM.match(masked[bounds[index] + 1:bounds[index + 1]])
            if not param:
                continue
            external, internal = param.group(1), param.group(2)
            if external == "_":
                rules.setdefault(name, set()).add(index)
            else:
                rules.setdefault(name, set()).add(external or internal)
    # Memberwise initializers: stored properties of structs.
    offset = 0
    for line in masked.split("\n"):
        stored = STORED.match(line)
        if stored and "{" not in line:
            owner = enclosing_type(masked, offset + len(line) - len(line.lstrip()))
            if owner:
                rules.setdefault(owner, set()).add(stored.group(1))
        offset += len(line) + 1


# --------------------------------------------------------------------------
# Keys
# --------------------------------------------------------------------------


def format_key(lit: Literal, unknown: list[str], percent_escape: bool = True) -> str:
    out = []
    for part in lit.parts:
        if isinstance(part, str):
            out.append(part.replace("%", "%%") if percent_escape and not lit.plain else part)
        elif re.fullmatch(r"\\?\.\$\w+", part[1].strip()):
            # App Intents parameter reference in a summary: \(\.$target)
            out.append(shortcut_token(part[1]))
        else:
            out.append(specifier_for(part[1], unknown))
    return "".join(out)


SPECIFIER = re.compile(
    r"%#@(\w+)@|%%"
    r"|%(?:(\d+)\$)?([-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSaAp])")


def specifiers(value: str) -> dict[int, str]:
    """Argument position -> conversion, the way printf would consume them."""
    result: dict[int, str] = {}
    implicit = 0
    for found in SPECIFIER.finditer(value):
        if found.group(0) == "%%":
            continue
        if found.group(1):
            result[-1 - len(result)] = "#@" + found.group(1)
            continue
        if found.group(2):
            position = int(found.group(2))
        else:
            implicit += 1
            position = implicit
        result[position] = found.group(3)
    return result


def has_prose(key: str) -> bool:
    return bool(re.search(r"[^\W\d_]", SPECIFIER.sub("", key)))


@dataclass
class Use:
    path: str
    line: int
    reason: str


def all_literals(literals: list[Literal]):
    for lit in literals:
        yield lit
        yield from all_literals(lit.nested)


def scan_sources(strays: list | None = None):
    files = sorted(APP_SOURCES.rglob("*.swift"))
    lexed = {}
    rules = {name: set(sel) for name, sel in API_RULES.items()}
    for path in files:
        masked, literals = lex(path.read_text(encoding="utf-8"))
        lexed[path] = (masked, literals)
        discover_rules(masked, rules)
    keys: dict[str, list[Use]] = {}
    phrases: dict[str, list[Use]] = {}
    unknown: list[tuple[str, int, str]] = []
    mixed: list[tuple[str, int, str]] = []
    for path, (masked, literals) in lexed.items():
        rel = str(path.relative_to(ROOT))
        for lit in all_literals(literals):
            if is_shortcut_phrase(lit):
                phrase = "".join(
                    p if isinstance(p, str) else shortcut_token(p[1]) for p in lit.parts)
                phrases.setdefault(phrase, []).append(Use(rel, lit.line, "phrase"))
                continue
            reason = localized_reason(lit, rules)
            if reason is not None and reason.startswith(MIXED):
                if has_prose(format_key(lit, [])):
                    mixed.append((rel, lit.line, lit.text()))
                continue
            if reason is None:
                if strays is not None and looks_like_prose(lit):
                    strays.append((rel, lit.line, lit.text()))
                continue
            missing: list[str] = []
            key = format_key(lit, missing)
            unknown.extend((rel, lit.line, e) for e in missing)
            if has_prose(key):
                keys.setdefault(key, []).append(Use(rel, lit.line, reason))
    return keys, phrases, unknown, mixed


def is_shortcut_phrase(lit: Literal) -> bool:
    return any(not isinstance(p, str) and p[1].strip() == ".applicationName"
               for p in lit.parts)


def shortcut_token(expression: str) -> str:
    expr = expression.strip()
    if expr == ".applicationName":
        return "${applicationName}"
    # Parameter placeholders: \(\.$station) -> ${station}
    found = re.fullmatch(r"\\?\.\$(\w+)", expr)
    return "${" + (found.group(1) if found else expr) + "}"


def looks_like_prose(lit: Literal) -> bool:
    text = "".join(p for p in lit.parts if isinstance(p, str))
    if not re.search(r"[A-Za-z]{2}", text):
        return False
    before = lit.masked[max(0, lit.start - 60):lit.start]
    if re.search(r"(systemName|systemImage|forKey|identifier|named|category|"
                 r"subsystem|label|name|withName|key|path|forInfoDictionaryKey|Logger\w*|log\.\w+|"
                 r"print|assert\w*|fatalError|precondition\w*|#available|"
                 r"forHTTPHeaderField|queryItems?|URL|string|rawValue|case \w+ =)"
                 r"\s*[:(=]?\s*$", before):
        return False
    return bool(re.search(r"[A-Z a-z]", text)) and (" " in text or text[:1].isupper())


# --------------------------------------------------------------------------
# Catalog checks
# --------------------------------------------------------------------------


def string_units(localization: dict):
    """Yield (description, unit) for every stringUnit in one localization."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, cases in localization.get("variations", {}).items():
        for case, inner in cases.items():
            for desc, unit in string_units(inner):
                yield f"{kind}.{case}{desc and '/' + desc}", unit
    for name, substitution in localization.get("substitutions", {}).items():
        for desc, unit in string_units(substitution):
            yield f"substitution {name}/{desc}", unit


def check_entry(key: str, entry: dict, errors: list[str]) -> None:
    localizations = entry.get("localizations", {})
    german = localizations.get(LANGUAGE)
    if not german:
        errors.append(f"no '{LANGUAGE}' translation: {key!r}")
        return
    expected = specifiers(key)
    for language, localization in localizations.items():
        units = list(string_units(localization))
        if not units:
            errors.append(f"empty '{language}' localization: {key!r}")
        substitutions = localization.get("substitutions", {})
        for where, unit in units:
            value = unit.get("value", "")
            if language == LANGUAGE and unit.get("state") != "translated":
                errors.append(
                    f"'{LANGUAGE}' not in state 'translated' ({where or 'value'}): {key!r}")
            if not value.strip():
                errors.append(f"empty '{language}' value ({where or 'value'}): {key!r}")
            if where.startswith("substitution"):
                # Inside a substitution the number is written "%arg"; nothing
                # else may be formatted there.
                name = where.split()[1].split("/")[0]
                arg = substitutions[name].get("argNum", 1)
                wanted = substitutions[name].get("formatSpecifier", "")
                if expected.get(arg) != wanted:
                    errors.append(
                        f"substitution '{name}' of {key!r} ({language}): argument {arg} "
                        f"of the key is %{expected.get(arg)}, not %{wanted}")
                if specifiers(value.replace("%arg", "")):
                    errors.append(
                        f"substitution '{name}' of {key!r} ({language}) may only use %arg: {value!r}")
                continue
            got = specifiers(value)
            # Substitution references stand for their argument.
            for position in [p for p in got if p < 0]:
                name = got.pop(position)[2:]
                if name not in substitutions:
                    errors.append(f"unknown substitution %#@{name}@ in {key!r} ({language})")
                    continue
                got[substitutions[name].get("argNum", 1)] = substitutions[name].get(
                    "formatSpecifier", "")
            # A plural case may drop the number ("one song"), never add one.
            plural = where.startswith("plural")
            mismatch = {p: c for p, c in got.items() if expected.get(p) != c}
            dropped = {p: c for p, c in expected.items() if p not in got}
            if mismatch or (dropped and not plural):
                errors.append(
                    f"format specifiers differ ({language}{', ' + where if where else ''}): "
                    f"{key!r} has {expected}, {value!r} has {got}")


def parse_strings_file(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    entries = {}
    pattern = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    for found in pattern.finditer(text):
        entries[found.group(1).replace('\\"', '"')] = found.group(2).replace('\\"', '"')
    leftovers = pattern.sub("", text)
    leftovers = "\n".join(ln for ln in leftovers.split("\n")
                          if ln.strip() and not ln.strip().startswith("//"))
    if leftovers.strip():
        raise LocalizationError(f"{path.name}: cannot parse: {leftovers.strip()[:80]!r}")
    return entries


def usage_description_keys() -> list[str]:
    keys = ["CFBundleDisplayName"]
    for found in re.finditer(r"^\s+(NS\w+UsageDescription)\s*:", PROJECT_YML.read_text(), re.M):
        keys.append(found.group(1))
    return keys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--keys", action="store_true", help="list keys found in code")
    parser.add_argument("--strays", action="store_true",
                        help="list prose-like literals that are not keys")
    args = parser.parse_args()

    strays: list = [] if args.strays else None  # type: ignore[assignment]
    keys, phrases, unknown, mixed = scan_sources(strays)

    if args.strays:
        for path, line, text in strays:
            print(f"{path}:{line}: {text!r}")
        return 0
    if args.keys:
        for key in sorted(keys):
            use = keys[key][0]
            print(f"{key!r}\t{use.path}:{use.line}\t{use.reason}")
        for phrase in sorted(phrases):
            print(f"{phrase!r}\t{phrases[phrase][0].path}\tApp Shortcut phrase")
        return 0

    errors: list[str] = []
    warnings: list[str] = []

    for path, line, expression in unknown:
        errors.append(
            f"{path}:{line}: cannot tell the type of interpolation \\({expression}); "
            "add it to INTERPOLATION_TYPES in scripts/check-localization.py")

    for path, line, text in mixed:
        errors.append(
            f"{path}:{line}: {text!r} shares a ternary with a non-literal branch, so it "
            "is a plain String and not localized; wrap it in String(localized:)")

    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"error: {CATALOG.relative_to(ROOT)}: {error}")
        return 1
    if catalog.get("sourceLanguage") != "en" or catalog.get("version") != "1.0":
        errors.append("Localizable.xcstrings: sourceLanguage must be 'en', version '1.0'")
    entries = catalog.get("strings", {})

    for key in sorted(keys):
        use = keys[key][0]
        if key not in entries:
            errors.append(f"{use.path}:{use.line}: missing from catalog: {key!r}")
    for key in sorted(entries):
        check_entry(key, entries[key], errors)
        if key not in keys:
            warnings.append(f"stale (no code uses it): {key!r}")

    # App Shortcut phrases (legacy .strings table, see docs/LOCALIZATION.md).
    shortcut_strings: dict[str, str] = {}
    if phrases and not SHORTCUT_STRINGS.exists():
        warnings.append(
            f"{SHORTCUT_STRINGS.relative_to(ROOT)} does not exist: the "
            f"{len(phrases)} App Shortcut phrases are English-only")
        phrases = {}
    elif phrases:
        try:
            shortcut_strings = parse_strings_file(SHORTCUT_STRINGS)
        except (OSError, LocalizationError) as error:
            errors.append(f"AppShortcuts.strings: {error}")
            phrases = {}
    for phrase in sorted(phrases):
        use = phrases[phrase][0]
        german = shortcut_strings.get(phrase)
        if german is None:
            errors.append(f"{use.path}:{use.line}: App Shortcut phrase has no German: {phrase!r}")
            continue
        if sorted(re.findall(r"\$\{\w+\}", german)) != sorted(re.findall(r"\$\{\w+\}", phrase)):
            errors.append(f"AppShortcuts.strings: placeholders differ for {phrase!r}")
    for phrase, german in shortcut_strings.items():
        if "${applicationName}" in phrase and phrase not in phrases:
            warnings.append(f"stale App Shortcut phrase: {phrase!r}")
        elif "${applicationName}" not in phrase and phrase not in keys:
            # Tile titles (AppShortcut(shortTitle:)) are listed in both tables.
            warnings.append(f"stale App Shortcut title: {phrase!r}")
    # The English table exists so XcodeGen builds a variant group; it must
    # list the same phrases, unchanged.
    english_strings = SHORTCUT_STRINGS.parent.parent / "en.lproj" / SHORTCUT_STRINGS.name
    if shortcut_strings:
        try:
            english = parse_strings_file(english_strings)
            if set(english) != set(shortcut_strings) or any(k != v for k, v in english.items()):
                errors.append("en.lproj/AppShortcuts.strings must map every key of the "
                              "German table to itself")
        except (OSError, LocalizationError) as error:
            errors.append(f"en.lproj/AppShortcuts.strings: {error}")

    # Info.plist strings.
    try:
        info = json.loads(INFOPLIST_CATALOG.read_text(encoding="utf-8")).get("strings", {})
    except (OSError, ValueError) as error:
        errors.append(f"InfoPlist.xcstrings: {error}")
        info = {}
    for key in usage_description_keys():
        localizations = info.get(key, {}).get("localizations", {})
        for language in ("en", LANGUAGE):
            if not localizations.get(language, {}).get("stringUnit", {}).get("value"):
                errors.append(f"InfoPlist.xcstrings: {key} has no '{language}' value")

    for warning in warnings:
        print(f"warning: {warning}")
    for error in errors:
        print(f"error: {error}")
    print(f"{len(keys)} keys in code, {len(entries)} in catalog, "
          f"{len(phrases)} App Shortcut phrases; "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
