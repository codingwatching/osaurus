#!/usr/bin/env python3
"""Classify live runtime proof summaries against Osaurus proof rules.

The family runtime matrix already records model responses, token rates, cache
telemetry, and failed checks. This script converts those artifacts into the
project proof vocabulary: proven, partial, failed, or unproven. It is designed
to run after ``run-family-runtime-chat-matrix.sh`` and to keep live runtime
issue closure honest when a row lacks token/s, topology-specific cache proof,
media-path proof, or other required evidence.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from collections import Counter
from datetime import datetime, timezone
from typing import Any


PROTOCOL_MARKERS = (
    "<|tool",
    "</|",
    "<tool_call",
    "</tool_call",
    "<think>",
    "</think>",
    "DSML",
    "xml_function",
    "\ufffetool:",
    "\ufffeargs:",
    "\ufffereasoning:",
)

REQUIRED_PRIORITIES = {"required", "required-local"}


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: pathlib.Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def manifest_by_id(manifest_path: pathlib.Path) -> dict[str, dict[str, Any]]:
    rows = load_json(manifest_path)
    if not isinstance(rows, list):
        raise ValueError(f"manifest must be a list: {manifest_path}")
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        if isinstance(row, dict) and row.get("id"):
            out[str(row["id"])] = row
    return out


def first_summary_payload(row: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    for raw_path in row.get("summary_files") or []:
        path = pathlib.Path(str(raw_path))
        if not path.exists():
            continue
        try:
            payload = load_json(path)
        except Exception as exc:  # noqa: BLE001 - artifact parser should preserve error text
            return None, f"summary parse error for {path}: {exc!r}"
        if isinstance(payload, dict):
            return payload, str(path)
    return None, None


def row_requirements(manifest_row: dict[str, Any]) -> list[str]:
    requirements = [
        "visible_output",
        "tokens_per_second",
        "no_parser_marker_leak",
        "multi_turn_coherency",
    ]
    if manifest_row.get("required_cache_evidence"):
        requirements.append("cache_hit")
    topology = str(manifest_row.get("topology", "")).lower()
    model = str(manifest_row.get("model", "")).lower()
    row_id = str(manifest_row.get("id", "")).lower()
    if "vl" in topology or "-vl" in model or "-vl" in row_id or row_id.endswith("-vl"):
        requirements.append("media_payload")
    return requirements


def has_token_rate(payload: dict[str, Any]) -> bool:
    token_rates = payload.get("token_rates")
    if not isinstance(token_rates, dict):
        return False
    for value in token_rates.values():
        if not isinstance(value, dict):
            continue
        tokens = value.get("completion_tokens")
        rate = value.get("tokens_per_second")
        if isinstance(tokens, int) and tokens > 0 and isinstance(rate, (int, float)) and rate > 0:
            return True
    return False


def parser_leaks(payload: dict[str, Any]) -> list[str]:
    text = json.dumps(payload, ensure_ascii=False)
    return sorted(marker for marker in PROTOCOL_MARKERS if marker.lower() in text.lower())


def checks(payload: dict[str, Any]) -> dict[str, bool]:
    raw = payload.get("checks")
    if not isinstance(raw, dict):
        return {}
    return {str(key): bool(value) for key, value in raw.items()}


def failed_checks(payload: dict[str, Any]) -> list[str]:
    raw = payload.get("failed_checks")
    if not isinstance(raw, list):
        return []
    return [str(value) for value in raw]


def visible_output_present(payload: dict[str, Any]) -> bool:
    turns = payload.get("turns")
    if isinstance(turns, dict):
        text = turns.get("turn2_content")
        if isinstance(text, str) and text.strip():
            return True
    for key in ("first", "repeat"):
        value = payload.get(key)
        if isinstance(value, dict):
            text = value.get("text") or value.get("answer")
            if isinstance(text, str) and text.strip():
                return True
    return False


def multi_turn_coherent(payload: dict[str, Any]) -> bool:
    row_checks = checks(payload)
    required = [
        "history_valid_after_turn1",
        "turn2_no_tool_calls",
        "turn2_visible_mentions_3",
        "turn2_not_length_stop",
        "turn3_finish_tool_calls",
        "turn3_has_one_tool_call",
        "turn3_name_line_count",
        "turn3_args_exact",
    ]
    return all(row_checks.get(name) is True for name in required)


def cache_hit_proven(payload: dict[str, Any], manifest_row: dict[str, Any]) -> bool:
    required = manifest_row.get("required_cache_evidence") or []
    if not required:
        return True
    row_checks = checks(payload)
    failures = set(failed_checks(payload))
    for name in required:
        check_name = f"cache_evidence_{name}"
        if check_name in failures or row_checks.get(check_name) is not True:
            return False
    return True


def media_payload_proven(payload: dict[str, Any]) -> bool:
    row_checks = checks(payload)
    media_checks = [
        "first_mentions_red",
        "repeat_mentions_red",
        "stable_prefix_hash",
        "repeat_disk_l2_hit",
    ]
    has_real_payload = bool(payload.get("image") or payload.get("media") or payload.get("payload"))
    if has_real_payload and all(row_checks.get(name) is True for name in media_checks):
        return True
    return False


def requirement_blockers(payload: dict[str, Any], manifest_row: dict[str, Any]) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    requirements = row_requirements(manifest_row)

    if "visible_output" in requirements and not visible_output_present(payload):
        blockers.append(
            {
                "requirement": "visible_output",
                "message": "row lacks non-empty visible assistant output",
            }
        )
    if "tokens_per_second" in requirements and not has_token_rate(payload):
        blockers.append(
            {
                "requirement": "tokens_per_second",
                "message": "row lacks token/s for a generation turn",
            }
        )
    if "no_parser_marker_leak" in requirements:
        leaks = parser_leaks(payload)
        if leaks:
            blockers.append(
                {
                    "requirement": "no_parser_marker_leak",
                    "message": "row contains parser marker leaks: " + ", ".join(leaks),
                }
            )
    if "multi_turn_coherency" in requirements and not multi_turn_coherent(payload):
        blockers.append(
            {
                "requirement": "multi_turn_coherency",
                "message": "row lacks complete multi-turn tool/follow-up coherence",
            }
        )
    if "cache_hit" in requirements and not cache_hit_proven(payload, manifest_row):
        blockers.append(
            {
                "requirement": "cache_hit",
                "message": "row lacks required topology-specific cache evidence",
            }
        )
    if "media_payload" in requirements and not media_payload_proven(payload):
        blockers.append(
            {
                "requirement": "media_payload",
                "message": "VL/media row lacks real media payload, media routing, or media cache-hit proof",
            }
        )
    return blockers


def classify_row(row: dict[str, Any], manifest_rows: dict[str, dict[str, Any]]) -> dict[str, Any]:
    row_id = str(row.get("id", ""))
    manifest_row = manifest_rows.get(row_id, {"id": row_id})
    payload, payload_path = first_summary_payload(row)
    artifact_paths = [str(path) for path in row.get("summary_files") or []]

    result: dict[str, Any] = {
        "id": row_id,
        "model": manifest_row.get("model") or row.get("model"),
        "family": manifest_row.get("family"),
        "priority": manifest_row.get("priority"),
        "requirements": row_requirements(manifest_row),
        "artifact_paths": artifact_paths,
        "summary_path": payload_path,
    }

    if payload is None:
        result.update(
            {
                "verdict": "unproven",
                "acceptable_for_proven_claim": False,
                "blockers": [
                    {
                        "requirement": "artifact",
                        "message": "row has no readable summary payload",
                    }
                ],
                "warnings": [],
            }
        )
        return result

    blockers = requirement_blockers(payload, manifest_row)
    failed = failed_checks(payload)
    passed = payload.get("passed") is True and row.get("passed") is True

    if passed and not blockers:
        verdict = "proven"
    elif payload.get("passed") is False or str(row.get("status", "")).startswith("FAIL"):
        verdict = "failed"
    else:
        verdict = "partial"

    if passed and blockers:
        verdict = "partial"

    result.update(
        {
            "verdict": verdict,
            "acceptable_for_proven_claim": verdict == "proven",
            "blockers": blockers,
            "warnings": []
            if artifact_paths
            else [
                {
                    "requirement": "artifact",
                    "message": "row should keep at least one artifact path",
                }
            ],
            "failed_checks": failed,
            "cache_delta": payload.get("cache_delta", {}),
            "token_rates": payload.get("token_rates", {}),
        }
    )
    return result


def verdict_counts(rows: list[dict[str, Any]]) -> dict[str, int]:
    counts = Counter(str(row.get("verdict", "unproven")) for row in rows)
    return {key: counts.get(key, 0) for key in ("proven", "partial", "failed", "unproven")}


def required_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [row for row in rows if str(row.get("priority")) in REQUIRED_PRIORITIES]


def issue_coverage(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    required = required_rows(rows)
    required_not_proven = [
        row["id"] for row in required if row.get("verdict") != "proven"
    ]
    hy3_rows = [row for row in rows if str(row.get("family")) == "hy3"]
    media_rows = [
        row for row in rows if "media_payload" in row.get("requirements", [])
    ]

    runtime_matrix_verdict = "proven" if not required_not_proven and required else "partial"
    if not required:
        runtime_matrix_verdict = "unproven"

    return {
        "#1161": {
            "verdict": runtime_matrix_verdict,
            "note": "local-model corruption closure requires all required family rows to be proven",
            "required_rows_not_proven": required_not_proven,
        },
        "#1162": {
            "verdict": runtime_matrix_verdict,
            "note": "systematic runtime verification tracks the full required matrix",
            "required_rows_not_proven": required_not_proven,
        },
        "#1163": {
            "verdict": "proven"
            if any(row.get("verdict") == "proven" for row in hy3_rows)
            else "unproven",
            "note": "Hy3/harmony parser closure needs a local Hy3 row, not sibling inference",
            "rows": [row["id"] for row in hy3_rows],
        },
        "#903": {
            "verdict": "unproven",
            "note": "this tool/cache matrix does not claim system-prompt injection proof",
        },
        "#1228": {
            "verdict": "partial" if any(row.get("verdict") == "failed" for row in rows) else "unproven",
            "note": "crash closure needs a reporter-aligned crash/cancellation artifact",
        },
        "#1183": {
            "verdict": "proven"
            if media_rows and all(row.get("verdict") == "proven" for row in media_rows)
            else "unproven",
            "note": "native media closure needs real media-path rows with cache-salt and cache-hit proof",
            "rows": [row["id"] for row in media_rows],
        },
    }


def classify(summary_path: pathlib.Path, manifest_path: pathlib.Path) -> dict[str, Any]:
    summary = load_json(summary_path)
    if not isinstance(summary, dict):
        raise ValueError(f"summary must be an object: {summary_path}")
    manifest_rows = manifest_by_id(manifest_path)
    rows = [
        classify_row(row, manifest_rows)
        for row in summary.get("rows", [])
        if isinstance(row, dict)
    ]
    required_not_proven = [
        row["id"] for row in required_rows(rows) if row.get("verdict") != "proven"
    ]
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "summary_path": str(summary_path),
        "manifest_path": str(manifest_path),
        "artifact_root": summary.get("artifact_root"),
        "verdict_counts": verdict_counts(rows),
        "required_rows_not_proven": required_not_proven,
        "passed": not required_not_proven,
        "rows": rows,
        "issue_coverage": issue_coverage(rows),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("summary", type=pathlib.Path, help="matrix SUMMARY.json")
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("family-runtime-chat-matrix.json"),
    )
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when any required row is not proven",
    )
    args = parser.parse_args()

    output = args.output or args.summary.with_name("PROOF_CLASSIFICATION.json")
    report = classify(args.summary, args.manifest)
    save_json(output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 2 if args.strict and not report["passed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
