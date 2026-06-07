#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
CLASSIFIER = ROOT / "scripts/live-proof/classify-runtime-proof-summary.py"


def write(path: pathlib.Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")


def run_classifier(root: pathlib.Path, manifest: list[dict[str, object]], summary: dict[str, object]) -> dict[str, object]:
    manifest_path = root / "manifest.json"
    summary_path = root / "SUMMARY.json"
    output_path = root / "PROOF_CLASSIFICATION.json"
    write(manifest_path, manifest)
    write(summary_path, summary)
    subprocess.run(
        [
            sys.executable,
            str(CLASSIFIER),
            str(summary_path),
            "--manifest",
            str(manifest_path),
            "--output",
            str(output_path),
        ],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
    )
    return json.loads(output_path.read_text(encoding="utf-8"))


def matrix_summary(root: pathlib.Path, row_id: str, payload: dict[str, object]) -> dict[str, object]:
    row_dir = root / row_id
    row_dir.mkdir()
    payload_path = row_dir / "model_summary.json"
    write(payload_path, payload)
    return {
        "artifact_root": str(root),
        "rows": [
            {
                "id": row_id,
                "passed": payload.get("passed"),
                "status": f"PASS {row_id}" if payload.get("passed") else f"FAIL {row_id}",
                "summary_files": [str(payload_path)],
            }
        ],
    }


def base_payload() -> dict[str, object]:
    checks = {
        "history_valid_after_turn1": True,
        "turn2_no_tool_calls": True,
        "turn2_visible_mentions_3": True,
        "turn2_not_length_stop": True,
        "turn3_finish_tool_calls": True,
        "turn3_has_one_tool_call": True,
        "turn3_name_line_count": True,
        "turn3_args_exact": True,
        "turn1_no_protocol_leak": True,
        "turn2_no_protocol_leak": True,
        "turn3_no_protocol_leak": True,
        "cache_evidence_cache_topology": True,
        "cache_evidence_disk_l2_hits": True,
    }
    return {
        "passed": True,
        "checks": checks,
        "failed_checks": [],
        "turns": {"turn2_content": "The text has 3 lines."},
        "token_rates": {
            "turn2": {
                "completion_tokens": 8,
                "elapsed_seconds": 0.5,
                "tokens_per_second": 16.0,
            }
        },
        "cache_delta": {"block_disk_hits": 1},
    }


def test_proven_row() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        manifest = [
            {
                "id": "full-kv",
                "model": "model",
                "family": "minimax",
                "priority": "required",
                "topology": "full-kv",
                "required_cache_evidence": ["cache_topology", "disk_l2_hits"],
            }
        ]
        report = run_classifier(root, manifest, matrix_summary(root, "full-kv", base_payload()))
        row = report["rows"][0]
        assert row["verdict"] == "proven", row
        assert report["passed"] is True


def test_missing_token_rate_is_partial() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        payload = base_payload()
        payload["token_rates"] = {}
        manifest = [
            {
                "id": "missing-tps",
                "model": "model",
                "family": "qwen",
                "priority": "required",
                "topology": "hybrid-ssm",
                "required_cache_evidence": ["cache_topology", "disk_l2_hits"],
            }
        ]
        report = run_classifier(root, manifest, matrix_summary(root, "missing-tps", payload))
        row = report["rows"][0]
        assert row["verdict"] == "partial", row
        assert any(issue["requirement"] == "tokens_per_second" for issue in row["blockers"])
        assert report["passed"] is False


def test_vl_row_without_media_payload_is_not_proven() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        manifest = [
            {
                "id": "zaya-vl",
                "model": "zaya1-vl-8b-jangtq4",
                "family": "zaya",
                "priority": "required",
                "topology": "zaya-cca-vl",
                "required_cache_evidence": ["cache_topology", "disk_l2_hits"],
            }
        ]
        report = run_classifier(root, manifest, matrix_summary(root, "zaya-vl", base_payload()))
        row = report["rows"][0]
        assert row["verdict"] == "partial", row
        assert any(issue["requirement"] == "media_payload" for issue in row["blockers"])


def test_unreadable_row_is_unproven() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        manifest = [{"id": "missing", "priority": "required"}]
        summary = {
            "artifact_root": str(root),
            "rows": [{"id": "missing", "passed": None, "summary_files": [str(root / "missing.json")]}],
        }
        report = run_classifier(root, manifest, summary)
        row = report["rows"][0]
        assert row["verdict"] == "unproven", row
        assert report["passed"] is False


def main() -> int:
    test_proven_row()
    test_missing_token_rate_is_partial()
    test_vl_row_without_media_payload_is_not_proven()
    test_unreadable_row_is_unproven()
    print("runtime proof classifier tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
