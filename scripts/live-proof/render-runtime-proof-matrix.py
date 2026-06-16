#!/usr/bin/env python3
"""Render PROOF_CLASSIFICATION.json into a maintainer-readable proof matrix.

This script is deliberately a renderer only. It does not classify artifacts or
promote proof rows; ``classify-runtime-proof-summary.py`` remains the source of
verdicts.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from typing import Any


BEGIN = "<!-- BEGIN RUNTIME PROOF MATRIX -->"
END = "<!-- END RUNTIME PROOF MATRIX -->"

SCHEMA_ROWS = [
    {
        "id": "issue-903-system-prompt-injection-schema",
        "model": "all local chat runtimes",
        "family": "cross-family",
        "priority": "schema-required",
        "verdict": "unproven",
        "requirements": [
            "visible_output",
            "tokens_per_second",
            "no_parser_marker_leak",
            "multi_turn_coherency",
            "system_prompt_injection",
        ],
        "artifact_paths": [],
        "blockers": [
            {
                "message": (
                    "requires a live artifact with an explicit system-prompt injection probe, "
                    "visible output, token/s, multi-turn coherency, and no parser marker leakage"
                )
            }
        ],
        "schema_only": True,
    },
    {
        "id": "issue-1163-hy3-harmony-retro-validation-schema",
        "model": "Hy3/harmony local rows",
        "family": "hy3",
        "priority": "schema-required",
        "verdict": "unproven",
        "requirements": [
            "visible_output",
            "tokens_per_second",
            "no_parser_marker_leak",
            "multi_turn_coherency",
        ],
        "artifact_paths": [],
        "blockers": [
            {
                "message": (
                    "requires a Hy3/harmony live artifact; sibling model rows or source-only "
                    "parser checks do not prove this issue"
                )
            }
        ],
        "schema_only": True,
    },
]


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"classification must be a JSON object: {path}")
    return value


def escape_markdown(value: object) -> str:
    return str(value).replace("\n", "<br>").replace("|", "\\|")


def blocker_messages(row: dict[str, Any]) -> list[str]:
    messages = []
    for blocker in row.get("blockers") or []:
        if not isinstance(blocker, dict):
            continue
        message = str(blocker.get("message") or "")
        requirement = blocker.get("requirement")
        if requirement:
            messages.append(f"{requirement}: {message}")
        elif message:
            messages.append(message)
    return messages


def normalized_row(row: dict[str, Any]) -> dict[str, Any]:
    evidence = []
    summary_path = row.get("summary_path")
    if summary_path:
        evidence.append(str(summary_path))
    evidence.extend(str(path) for path in row.get("artifact_paths") or [] if path)
    evidence = list(dict.fromkeys(path for path in evidence if path))
    return {
        "id": str(row.get("id") or ""),
        "model": str(row.get("model") or row.get("id") or ""),
        "family": str(row.get("family") or "unknown"),
        "priority": str(row.get("priority") or "unspecified"),
        "verdict": str(row.get("verdict") or "unproven"),
        "requirements": sorted(str(value) for value in row.get("requirements") or [] if value),
        "evidence": evidence,
        "blockers": blocker_messages(row),
        "schema_only": bool(row.get("schema_only")),
    }


def matrix_rows(report: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [normalized_row(row) for row in report.get("rows") or [] if isinstance(row, dict)]
    existing_ids = {row["id"] for row in rows}
    for schema in SCHEMA_ROWS:
        if schema["id"] not in existing_ids:
            rows.append(normalized_row(schema))
    return sorted(rows, key=lambda row: (row["family"], row["model"], row["id"]))


def verdict_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    counts = Counter(row["verdict"] for row in rows)
    return {key: counts.get(key, 0) for key in ("proven", "partial", "failed", "unproven")}


def render_markdown(report: dict[str, Any], source: pathlib.Path, generated_at: str | None = None) -> str:
    rows = matrix_rows(report)
    lines = [
        BEGIN,
        "",
        f"Generated from {escape_markdown(source)} at {escape_markdown(generated_at or report.get('generated_at') or 'unknown')}.",
        "",
        "| Row | Model | Family | Verdict | Requirements | Evidence | Blockers |",
        "|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        values = [
            row["id"],
            row["model"],
            row["family"],
            row["verdict"],
            ", ".join(row["requirements"]),
            "<br>".join(row["evidence"]) if row["evidence"] else "none",
            "<br>".join(row["blockers"]) if row["blockers"] else "none",
        ]
        lines.append("| " + " | ".join(escape_markdown(value) for value in values) + " |")
    lines.extend(["", END, ""])
    return "\n".join(lines)


def replace_marked_matrix(document: str, matrix: str) -> str:
    begin = document.find(BEGIN)
    if begin == -1:
        separator = "\n" if document.endswith("\n") else "\n\n"
        return document + separator + matrix
    end = document.find(END, begin)
    if end == -1:
        raise ValueError(f"found {BEGIN} without {END}")
    return document[:begin] + matrix + document[end + len(END) :]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("classification", type=pathlib.Path, help="PROOF_CLASSIFICATION.json")
    parser.add_argument("--output", type=pathlib.Path, help="write matrix markdown to this file")
    parser.add_argument("--update-doc", type=pathlib.Path, help="replace or append the marked matrix in this doc")
    parser.add_argument("--generated-at", help="override generated timestamp for deterministic tests")
    parser.add_argument("--json-surface", type=pathlib.Path, help="write the read-only row surface as JSON")
    args = parser.parse_args()

    report = load_json(args.classification)
    matrix = render_markdown(report, args.classification, generated_at=args.generated_at)

    if args.json_surface:
        rows = matrix_rows(report)
        args.json_surface.write_text(
            json.dumps(
                {
                    "generated_at": args.generated_at or report.get("generated_at") or "unknown",
                    "source_classification_path": str(args.classification),
                    "artifact_root": report.get("artifact_root"),
                    "verdict_counts": verdict_counts(rows),
                    "rows": rows,
                    "issue_coverage": report.get("issue_coverage") or {},
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    if args.update_doc:
        document = args.update_doc.read_text(encoding="utf-8")
        args.update_doc.write_text(replace_marked_matrix(document, matrix), encoding="utf-8")
    elif args.output:
        args.output.write_text(matrix, encoding="utf-8")
    else:
        print(matrix, end="")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
