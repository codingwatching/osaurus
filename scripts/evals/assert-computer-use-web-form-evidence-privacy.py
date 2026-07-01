#!/usr/bin/env python3
"""Verify web-form proof artifacts keep form contents out of evidence."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def collect_fixture_values(case_path: Path) -> set[str]:
    case = json.loads(case_path.read_text())
    loop = case["expect"]["computerUseLoop"]
    values: set[str] = set()

    for raw in loop.get("scriptedActions", []):
        try:
            action = json.loads(raw)
        except json.JSONDecodeError:
            continue
        value = action.get("text")
        if isinstance(value, str) and value:
            values.add(value)

    return values


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: assert-computer-use-web-form-evidence-privacy.py "
            "<case.json> <artifact> [<artifact> ...]",
            file=sys.stderr,
        )
        return 2

    case_path = Path(argv[1])
    artifacts = [Path(arg) for arg in argv[2:]]
    fixture_values = collect_fixture_values(case_path)
    if not fixture_values:
        print(
            f"Computer Use web-form evidence privacy check failed: no fixture values found in {case_path}",
            file=sys.stderr,
        )
        return 1
    forbidden_literals = fixture_values | {
        "base64",
        "data:image",
        '"image"',
        '"base64"',
    }

    failures: list[str] = []
    for artifact in artifacts:
        if not artifact.exists():
            failures.append(f"{artifact}: missing artifact")
            continue
        text = artifact.read_text(errors="replace")
        if not text.strip():
            failures.append(f"{artifact}: empty artifact")
            continue
        for literal in forbidden_literals:
            if literal and literal in text:
                failures.append(f"{artifact}: contains forbidden literal {literal!r}")

    if failures:
        print("Computer Use web-form evidence privacy check failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(
        "Computer Use web-form evidence privacy check passed "
        f"({len(artifacts)} artifact(s), {len(fixture_values)} fixture value(s))."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
