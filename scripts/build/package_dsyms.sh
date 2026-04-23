#!/usr/bin/env bash
set -euo pipefail

# Collects every .dSYM bundle produced by build_arm64.sh and zips them into a
# single asset that can be uploaded alongside the DMG. dSYMs are required to
# symbolicate field crash reports — once a build is shipped without them, the
# matching binary UUIDs are gone forever and atos can't recover symbols.
#
# Sources:
#   build/osaurus.xcarchive/dSYMs/                — App + embedded frameworks
#   build/Build/Products/Release/*.dSYM           — osaurus-cli (built outside
#                                                    the archive, so it lands
#                                                    next to the binary instead
#                                                    of inside the archive).

: "${VERSION:?VERSION is required}"

ARCHIVE_DSYMS_DIR="build/osaurus.xcarchive/dSYMs"
CLI_BUILD_DIR="build/Build/Products/Release"
STAGE_DIR="build_output/dsyms-stage"
OUT_ZIP="build_output/Osaurus-${VERSION}-dSYMs.zip"

mkdir -p "${STAGE_DIR}"

shopt -s nullglob

copied_any=false

# App + embedded framework/dylib dSYMs from the archive
if [[ -d "${ARCHIVE_DSYMS_DIR}" ]]; then
  for dsym in "${ARCHIVE_DSYMS_DIR}"/*.dSYM; do
    cp -R "${dsym}" "${STAGE_DIR}/"
    copied_any=true
  done
fi

# CLI dSYM lives next to the CLI binary because it was built via `build`,
# not `archive`. Skip silently if the CLI scheme didn't emit one (e.g. when
# DEBUG_INFORMATION_FORMAT was overridden).
if [[ -d "${CLI_BUILD_DIR}" ]]; then
  for dsym in "${CLI_BUILD_DIR}"/*.dSYM; do
    cp -R "${dsym}" "${STAGE_DIR}/"
    copied_any=true
  done
fi

if [[ "${copied_any}" != "true" ]]; then
  echo "::warning::No .dSYM bundles found in ${ARCHIVE_DSYMS_DIR} or ${CLI_BUILD_DIR}; skipping dSYM packaging."
  rmdir "${STAGE_DIR}" 2>/dev/null || true
  exit 0
fi

# Print contents and UUIDs so the CI log records exactly what was shipped —
# UUIDs are how atos pairs a future crash report with this archive.
echo "Packaging dSYMs:"
for dsym in "${STAGE_DIR}"/*.dSYM; do
  echo "  - $(basename "${dsym}")"
  if command -v dwarfdump >/dev/null 2>&1; then
    # `|| true` so a malformed dSYM (or one that lacks a DWARF binary, e.g.
    # a Swift framework with stripped symbols) doesn't abort the release
    # via `set -euo pipefail`. Logging the UUIDs is best-effort.
    dwarfdump --uuid "${dsym}" 2>/dev/null | sed 's/^/      /' || true
  fi
done

# Use ditto so the macOS-specific bundle attributes (HFS+ metadata, code-sign
# extended attrs on the binary inside the dSYM) survive the round trip. The
# `--keepParent` flag would nest under `dsyms-stage/`; we want the dSYMs at
# the zip root.
ditto -c -k --sequesterRsrc "${STAGE_DIR}" "${OUT_ZIP}"

rm -rf "${STAGE_DIR}"

echo "✅ Wrote ${OUT_ZIP} ($(du -h "${OUT_ZIP}" | cut -f1))"
