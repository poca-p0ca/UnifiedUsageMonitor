#!/usr/bin/env python3
"""Keeps the string tables and the Swift fallbacks in agreement.

Every L10n call carries the English text twice: as the fallback argument (which
is what `--probe` on a bare binary prints, and what any missing key falls back
to) and as the value in en.lproj. Nothing forces those to match, so this checks
it, and at the same time reports keys a translation is missing or no longer
uses.

    python3 tools/check-strings.py
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"
DEVELOPMENT_LANGUAGE = "en"

# L10n.t("key", "fallback")  /  L10n.f("key", "fallback", args...)
# Fallbacks may span lines and contain escapes, but never interpolation.
CALL = re.compile(
    r'L10n\.[tf]\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"',
    re.DOTALL,
)
# "key" = "value";  with C-style comments already stripped.
ENTRY = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def unescape(text: str) -> str:
    return text.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


def swift_calls() -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        for key, fallback in CALL.findall(path.read_text()):
            found.setdefault(key, set()).add(unescape(fallback))
    return found


def table(language: str) -> dict[str, str]:
    path = RESOURCES / f"{language}.lproj" / "Localizable.strings"
    text = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.DOTALL)
    return {unescape(k): unescape(v) for k, v in ENTRY.findall(text)}


def main() -> int:
    calls = swift_calls()
    languages = sorted(p.name[: -len(".lproj")] for p in RESOURCES.glob("*.lproj"))
    if DEVELOPMENT_LANGUAGE not in languages:
        print(f"✗ no {DEVELOPMENT_LANGUAGE}.lproj", file=sys.stderr)
        return 1

    problems: list[str] = []

    for key, fallbacks in sorted(calls.items()):
        if len(fallbacks) > 1:
            joined = " / ".join(repr(f) for f in sorted(fallbacks))
            problems.append(f"{key}: Swift uses more than one fallback — {joined}")

    for language in languages:
        entries = table(language)
        for key, fallbacks in sorted(calls.items()):
            if key not in entries:
                problems.append(f"{language}: missing key {key!r}")
            elif language == DEVELOPMENT_LANGUAGE and entries[key] not in fallbacks:
                problems.append(
                    f"{language}: {key!r} is {entries[key]!r} "
                    f"but the Swift fallback is {next(iter(fallbacks))!r}"
                )
        for key in sorted(set(entries) - set(calls)):
            problems.append(f"{language}: unused key {key!r}")

    if problems:
        for problem in problems:
            print(f"✗ {problem}", file=sys.stderr)
        return 1

    print(f"✓ {len(calls)} keys across {', '.join(languages)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
