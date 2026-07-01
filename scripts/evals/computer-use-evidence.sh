#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Run local, forensic Computer Use evidence.

Usage:
  scripts/evals/computer-use-evidence.sh

Environment:
  OUT_DIR=path        Evidence output directory.
                      Default: build/computer-use-evidence/<UTC timestamp>
  RUN_EVALS=1        Also run the Packages/OsaurusEvals ComputerUse and
                      ComputerUseLoop suites.
  MODEL=id           Model id passed to osaurus-evals when RUN_EVALS=1.
  STRICT=0           Always exit 0 after writing artifacts. Default exits nonzero
                      when a required command fails.

Requires `python3` for timing, manifest, and summary generation.

The runner writes logs, manifest.json, summary.md, and command-results.tsv under
OUT_DIR. build/ is gitignored, so generated evidence stays local by default.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

cd "$REPO_ROOT"

timestamp="$(date -u +"%Y%m%d-%H%M%S")"
OUT_DIR="${OUT_DIR:-build/computer-use-evidence/${timestamp}}"
LOG_DIR="${OUT_DIR}/logs"
RESULTS_TSV="${OUT_DIR}/command-results.tsv"
WEB_FORM_CASE="Packages/OsaurusEvals/Suites/ComputerUseLoop/web-form-proof-lab.json"
STRICT="${STRICT:-1}"
RUN_EVALS="${RUN_EVALS:-0}"
OSAURUS_TEST_ROOT="${OSAURUS_TEST_ROOT:-/tmp/osaurus-computer-use-evidence}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "error: ${PYTHON_BIN} is required to write Computer Use evidence artifacts." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
printf "name\tcommand\tlog\texit_code\tduration_ms\n" > "$RESULTS_TSV"

fail=0

quote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v out '%s%q ' "$out" "$arg"
  done
  printf '%s' "${out% }"
}

now_ms() {
  "$PYTHON_BIN" -c 'import time; print(int(time.time() * 1000))'
}

run_step() {
  local name="$1"
  shift
  local log="${LOG_DIR}/${name}.log"
  local rel_log="logs/${name}.log"
  local cmd_display
  cmd_display="$(quote_cmd "$@")"
  local start end duration rc
  start="$(now_ms)"
  echo "==> ${name}: ${cmd_display}"
  set +e
  "$@" >"$log" 2>&1
  rc=$?
  set -e
  end="$(now_ms)"
  duration=$((end - start))
  printf "%s\t%s\t%s\t%d\t%d\n" "$name" "$cmd_display" "$rel_log" "$rc" "$duration" >> "$RESULTS_TSV"
  if [[ "$rc" -eq 0 ]]; then
    echo "PASS ${name} (${duration}ms)"
  else
    echo "FAIL ${name} (${duration}ms); see ${log}" >&2
    fail=1
  fi
}

run_step git-diff-check git diff --check
run_step computer-use-evidence-pack \
  env OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$OSAURUS_TEST_ROOT" \
  swift test --package-path Packages/OsaurusCore --quiet --filter ComputerUseEvidencePackTests
run_step computer-use-suite \
  env OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$OSAURUS_TEST_ROOT" \
  swift test --package-path Packages/OsaurusCore --quiet --filter ComputerUse
run_step computer-use-web-form-privacy \
  "$PYTHON_BIN" scripts/evals/assert-computer-use-web-form-evidence-privacy.py \
    "$WEB_FORM_CASE" \
    "$LOG_DIR/computer-use-evidence-pack.log" \
    "$LOG_DIR/computer-use-suite.log"

if [[ "$RUN_EVALS" == "1" ]]; then
  run_step evals-build swift build --package-path Packages/OsaurusEvals --product osaurus-evals
  eval_cmd=(
    swift run --package-path Packages/OsaurusEvals osaurus-evals run
    --suite Packages/OsaurusEvals/Suites/ComputerUse
    --out "${OUT_DIR}/evals-computer-use.json"
  )
  if [[ -n "${MODEL:-}" ]]; then
    eval_cmd+=(--model "$MODEL")
  fi
  run_step evals-computer-use "${eval_cmd[@]}"
  loop_eval_cmd=(
    swift run --package-path Packages/OsaurusEvals osaurus-evals run
    --suite Packages/OsaurusEvals/Suites/ComputerUseLoop
    --out "${OUT_DIR}/evals-computer-use-loop.json"
  )
  if [[ -n "${MODEL:-}" ]]; then
    loop_eval_cmd+=(--model "$MODEL")
  fi
  run_step evals-computer-use-loop "${loop_eval_cmd[@]}"
else
  echo "RUN_EVALS is not 1; skipping model-dependent ComputerUse and ComputerUseLoop eval suites."
fi

{
  echo "branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "head $(git rev-parse HEAD 2>/dev/null || true)"
  echo "origin_main $(git rev-parse origin/main 2>/dev/null || true)"
  echo "dirty_lines $(git status --short | wc -l | tr -d ' ')"
  echo "swift $(swift --version 2>/dev/null | head -1)"
  echo "xcodebuild $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  echo "run_evals ${RUN_EVALS}"
  if [[ -n "${MODEL:-}" ]]; then echo "model ${MODEL}"; fi
} > "${OUT_DIR}/environment.txt"

"$PYTHON_BIN" - "$OUT_DIR" "$RESULTS_TSV" "$fail" <<'PY'
import csv
import json
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

out_dir = pathlib.Path(sys.argv[1])
tsv = pathlib.Path(sys.argv[2])
failed = sys.argv[3] != "0"

steps = []
with tsv.open(newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        steps.append(
            {
                "name": row["name"],
                "command": row["command"],
                "log": row["log"],
                "exit_code": int(row["exit_code"]),
                "duration_ms": int(row["duration_ms"]),
            }
        )

def git(args):
    try:
        return subprocess.check_output(["git", *args], text=True).strip()
    except Exception:
        return ""

manifest = {
    "schema": 1,
    "kind": "computer_use_evidence",
    "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "head": git(["rev-parse", "HEAD"]),
    "branch": git(["rev-parse", "--abbrev-ref", "HEAD"]),
    "origin_main": git(["rev-parse", "origin/main"]),
    "dirty_status_lines": git(["status", "--short"]).splitlines(),
    "result": "failed" if failed else "passed",
    "commands": steps,
    "artifacts": {
        "summary": "summary.md",
        "environment": "environment.txt",
        "command_results": "command-results.tsv",
    },
    "fixtures": {
        "web_form": "Packages/OsaurusCore/Tests/ComputerUse/Fixtures/WebForm/",
    },
}

(out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

lines = [
    "# Computer Use Evidence",
    "",
    f"- Result: **{manifest['result']}**",
    f"- Branch: `{manifest['branch']}`",
    f"- Head: `{manifest['head']}`",
    f"- Created: `{manifest['created_at']}`",
    "",
    "| Step | Exit | Duration | Log |",
    "| --- | ---: | ---: | --- |",
]
for step in steps:
    seconds = step["duration_ms"] / 1000.0
    lines.append(
        f"| `{step['name']}` | {step['exit_code']} | {seconds:.2f}s | `{step['log']}` |"
    )
lines.extend(
    [
        "",
        "Generated by `scripts/evals/computer-use-evidence.sh`.",
        "Artifacts live under `build/` and are intentionally ignored by git.",
        "",
    ]
)
(out_dir / "summary.md").write_text("\n".join(lines))
PY

echo "Wrote Computer Use evidence to ${OUT_DIR}"
echo "Summary: ${OUT_DIR}/summary.md"

if [[ "$fail" -ne 0 && "$STRICT" != "0" ]]; then
  exit 1
fi
