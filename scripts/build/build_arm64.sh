#!/usr/bin/env bash
set -euo pipefail

# Backward-compat: if DEVELOPMENT_TEAM not set, fall back to APPLE_TEAM_ID
if [[ -z "${DEVELOPMENT_TEAM:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  export DEVELOPMENT_TEAM="${APPLE_TEAM_ID}"
fi

: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required}"
: "${DEVELOPER_ID_NAME:?DEVELOPER_ID_NAME is required}"
: "${VERSION:?VERSION is required}"

echo "Building ARM64 version (default)..."

# Normalize identity: allow DEVELOPER_ID_NAME with or without the product prefix
CODE_SIGN_IDENTITY_VALUE="${DEVELOPER_ID_NAME}"
if [[ "${CODE_SIGN_IDENTITY_VALUE}" != Developer\ ID\ Application:* ]]; then
  CODE_SIGN_IDENTITY_VALUE="Developer ID Application: ${CODE_SIGN_IDENTITY_VALUE}"
fi

# Ensure a clean build environment before archiving
rm -rf build/DerivedData build/SourcePackages
xcodebuild -resolvePackageDependencies -workspace osaurus.xcworkspace -scheme osaurus -clonedSourcePackagesDirPath build/SourcePackages -disableAutomaticPackageResolution

# 1. Build the CLI first (as a separate scheme)
echo "Building CLI (OsaurusCLI)..."
xcodebuild -workspace osaurus.xcworkspace \
  -scheme osaurus-cli \
  -configuration Release \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY_VALUE}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  clean build

# 2. Archive the App (which doesn't have the CLI embedded yet via Xcode)
#
# `keychain-access-groups` is a profile-managed entitlement: `xcodebuild`
# refuses to sign it without a provisioning profile, even under manual Developer
# ID signing. Osaurus ships Developer ID without a profile, so the archive and
# export passes run against a copy of the entitlements with that key stripped;
# the full set is re-applied to the shipped app by the post-export re-sign at
# the bottom of this script, where `codesign` embeds the access group directly
# with no profile required.
#
# osaurus.entitlements stays the single source of truth: the stripped file is
# generated from it here, and local Xcode dev keeps using the full file via
# automatic signing (which provisions the access group automatically).
#
# PROFILE_MANAGED_ENTITLEMENTS is a list (not a single key) so that adding
# another profile-managed entitlement to osaurus.entitlements (e.g.
# `aps-environment`, `application-identifier`, or a `com.apple.developer.*`
# capability) doesn't silently reintroduce the "requires a provisioning profile"
# archive/export failure. Add any such new key here too.
echo "Generating profile-free archive entitlements..."
mkdir -p build
ARCHIVE_ENTITLEMENTS="${PWD}/build/osaurus.archive.entitlements"
cp "App/osaurus/osaurus.entitlements" "$ARCHIVE_ENTITLEMENTS"

PROFILE_MANAGED_ENTITLEMENTS=(
  "keychain-access-groups"
)
for key in "${PROFILE_MANAGED_ENTITLEMENTS[@]}"; do
  /usr/libexec/PlistBuddy -c "Delete :${key}" "$ARCHIVE_ENTITLEMENTS" >/dev/null 2>&1 || true
  if /usr/libexec/PlistBuddy -c "Print :${key}" "$ARCHIVE_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Error: failed to strip profile-managed entitlement '${key}' from archive entitlements" >&2
    exit 1
  fi
done

echo "Archiving App (osaurus)..."
xcodebuild -workspace osaurus.xcworkspace \
  -scheme osaurus \
  -configuration Release \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  VALID_ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${VERSION}" \
  CODE_SIGN_ENTITLEMENTS="$ARCHIVE_ENTITLEMENTS" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY_VALUE}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Manual \
  archive -archivePath build/osaurus.xcarchive

# 3. Manually Embed the CLI into the Archive
echo "Embedding CLI into Archive (Helpers)..."
CLI_SRC="build/Build/Products/Release/osaurus-cli"
ARCHIVE_APP="build/osaurus.xcarchive/Products/Applications/Osaurus.app"

if [[ ! -f "$CLI_SRC" ]]; then
  echo "Error: CLI binary not found at $CLI_SRC"
  exit 1
fi

# Copy to Helpers folder as 'osaurus'
mkdir -p "$ARCHIVE_APP/Contents/Helpers"
cp "$CLI_SRC" "$ARCHIVE_APP/Contents/Helpers/osaurus"
chmod +x "$ARCHIVE_APP/Contents/Helpers/osaurus"

# Resolve `$(AppIdentifierPrefix)` for the POST-EXPORT re-sign at the bottom.
#
# codesign does NOT expand Xcode build variables. osaurus.entitlements uses
# `$(AppIdentifierPrefix)` (== "<TeamID>.") for the keychain-access-groups value,
# which only Xcode resolves during its packaging phase. Signing with the raw
# file would embed the literal `$(AppIdentifierPrefix)com.dinoki.osaurus` — an
# invalid access group that makes the data-protection keychain return
# errSecMissingEntitlement at runtime and silently fall back to the legacy login
# keychain, reintroducing the "wants to use your confidential information" prompt
# in production while working fine in local Xcode builds.
echo "Resolving entitlements (AppIdentifierPrefix -> ${DEVELOPMENT_TEAM}.)..."
RESOLVED_ENTITLEMENTS="build/osaurus.resolved.entitlements"
sed "s|\$(AppIdentifierPrefix)|${DEVELOPMENT_TEAM}.|g" "App/osaurus/osaurus.entitlements" > "$RESOLVED_ENTITLEMENTS"
if grep -q 'AppIdentifierPrefix' "$RESOLVED_ENTITLEMENTS"; then
  echo "Error: failed to resolve \$(AppIdentifierPrefix) in entitlements" >&2
  exit 1
fi

# Re-sign the archived app (now carrying the embedded CLI) with the STRIPPED,
# profile-free entitlements — NOT the resolved set. `--deep` also signs the
# nested CLI binary. If this re-sign put keychain-access-groups back into the
# archive (and its nested Sparkle Updater.app / Downloader.xpc / Installer.xpc),
# the following `xcodebuild -exportArchive` would see the profile-managed
# entitlement and fail every component with "requires a provisioning profile"
# (** EXPORT FAILED **). Keeping the archive profile-free lets export succeed;
# keychain-access-groups is restored on the shipped app by the post-export
# re-sign below.
echo "Re-signing modified app bundle (profile-free entitlements)..."
codesign --force --deep --options runtime --entitlements "$ARCHIVE_ENTITLEMENTS" --sign "${CODE_SIGN_IDENTITY_VALUE}" "$ARCHIVE_APP"

cat > ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/osaurus.xcarchive \
  -exportPath build_output \
  -exportOptionsPlist ExportOptions.plist

# Restore full entitlements (post-export)
#
# `xcodebuild -exportArchive` re-signs the app from the archive's captured
# entitlements, which omit `keychain-access-groups` (stripped above so the
# `archive` action wouldn't demand a provisioning profile). Re-apply the full
# resolved entitlement set with a final TOP-LEVEL re-sign so the shipped binary
# carries the data-protection keychain access group. `codesign` embeds the
# team-prefixed group directly under Developer ID — no provisioning profile
# required.
#
#  - No `--deep`: nested code (frameworks, embedded CLI) is already validly
#    signed by export; only the outer bundle's entitlements/seal change here.
#  - `--timestamp`: re-signing drops export's secure timestamp, which
#    notarization requires; request a fresh one.
EXPORTED_APP="build_output/Osaurus.app"
if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Error: exported app not found at $EXPORTED_APP" >&2
  exit 1
fi

echo "Restoring full entitlements on exported app (post-export re-sign)..."
codesign --force --timestamp --options runtime \
  --entitlements "$RESOLVED_ENTITLEMENTS" \
  --sign "${CODE_SIGN_IDENTITY_VALUE}" \
  "$EXPORTED_APP"
