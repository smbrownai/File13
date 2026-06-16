#!/bin/bash
#
# Build, sign, notarize, and package the file13 CLI for distribution.
#
# Run from the cli/ directory:
#   cli/Scripts/release.sh 0.1.0
#
# Required env / setup:
#   - Xcode + xcrun toolchain
#   - DEVELOPER_ID env var, e.g.
#       export DEVELOPER_ID="Developer ID Application: Shawn Brown (YRB6VBTSRV)"
#   - notarytool keychain profile created once with:
#       xcrun notarytool store-credentials file13-notary \
#         --apple-id <your-apple-id> \
#         --team-id YRB6VBTSRV \
#         --password <app-specific-password from appleid.apple.com>
#   - NOTARY_PROFILE env var (default: file13-notary)
#
# Output: cli/.build/dist/file13-<version>-arm64-macos.tar.gz + .sha256
#
# The script intentionally does NOT push to a Homebrew tap — that's a manual
# step (commit the formula update to your tap repo) so you can review the
# version + URL + SHA before publishing. The summary line at the end prints
# the exact formula stanza to paste.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   (e.g. 0.1.0)" >&2
    exit 64
fi

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "error: set DEVELOPER_ID, e.g.:" >&2
    echo "  export DEVELOPER_ID=\"Developer ID Application: Shawn Brown (YRB6VBTSRV)\"" >&2
    exit 64
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-file13-notary}"

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CLI_DIR"

# Verify the source's file13Version matches $VERSION *before* the
# build. The previous post-build sanity check ran the freshly-built
# binary with `file13 version`, which is impossible on a CI runner
# whose macOS version (15) is older than the binary's deployment
# target (26.0) — dyld refuses to load and the process SIGABRTs.
# Source grep gives the same guarantee without needing to execute.
SOURCE_VERSION=$(sed -n 's/^let file13Version = "\([^"]*\)".*/\1/p' \
    "$CLI_DIR/Sources/file13/File13.swift" | head -1)
if [[ -z "$SOURCE_VERSION" ]]; then
    echo "error: couldn't extract file13Version from cli/Sources/file13/File13.swift" >&2
    exit 1
fi
if [[ "$SOURCE_VERSION" != "$VERSION" ]]; then
    echo "error: source declares file13Version=\"$SOURCE_VERSION\" but release was asked for \"$VERSION\"" >&2
    echo "       bump file13Version in cli/Sources/file13/File13.swift first" >&2
    exit 1
fi
echo "==> source declares file13Version=\"$SOURCE_VERSION\" — matches requested $VERSION."

DIST_DIR="$CLI_DIR/.build/dist"
STAGE_DIR="$DIST_DIR/file13-$VERSION"
# notarytool accepts .zip / .pkg / .dmg only. Use .zip via `ditto` — the
# macOS-native zip producer that preserves bundle structure and resource
# forks the way Apple's signing chain expects.
ARCHIVE_NAME="file13-$VERSION-arm64-macos.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
ENTITLEMENTS="$CLI_DIR/file13.entitlements"

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

echo "==> swift build (release) targeting arm64..."
# Don't hardcode DEVELOPER_DIR — that overrides whatever the caller's
# `xcode-select` chose, and the CI runner's bare `/Applications/Xcode.app`
# symlink can point at an older Xcode than the explicit Xcode_26.x we want.
# Trust the active developer dir; print it for log clarity.
echo "    using Xcode at: $(xcode-select -p)"
echo "    swift version : $(xcrun swift --version | head -1)"
xcrun swift build \
    --package-path "$CLI_DIR" \
    --configuration release \
    --triple arm64-apple-macosx26.0

BIN_PATH="$CLI_DIR/.build/arm64-apple-macosx/release/file13"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> code-signing with Developer ID + hardened runtime (no entitlements)..."
# Why no --entitlements: macOS treats `application-groups` and
# `keychain-access-groups` as RESTRICTED entitlements that must be backed by
# an embedded provisioning profile. App bundles get one, bare CLI binaries
# don't, and amfid will refuse to launch the binary at runtime with
# `Error Code=-413 "No matching profile found"`.
#
# The CLI works around this by:
#   - reading the App Group container as a plain filesystem path
#     (~/Library/Group Containers/<group>/ is created by the GUI app and
#     any user-owned process can read+write the directory tree).
#   - managing its OWN Keychain entries in the default user keychain
#     (no kSecAttrAccessGroup), separate from the GUI's access-group
#     entries. API keys and IMAP passwords must be re-added on the CLI
#     side via `file13 accounts add` and (future) `file13 providers
#     set-key`.
codesign \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --timestamp \
    --force \
    "$BIN_PATH"

echo "==> verifying signature..."
codesign --verify --verbose=2 "$BIN_PATH"

echo "==> staging into $STAGE_DIR..."
cp "$BIN_PATH" "$STAGE_DIR/file13"
cp "$CLI_DIR/README.md" "$STAGE_DIR/"
if [[ -f "$CLI_DIR/../LICENSE" ]]; then
    cp "$CLI_DIR/../LICENSE" "$STAGE_DIR/"
fi

echo "==> creating archive $ARCHIVE_NAME..."
# `ditto -c -k --keepParent` mirrors the way Xcode itself archives — the
# resulting .zip is what notarytool / stapler are most reliable with.
( cd "$DIST_DIR" && ditto -c -k --keepParent "$(basename "$STAGE_DIR")" "$ARCHIVE_NAME" )

echo "==> verifying notarytool keychain profile '$NOTARY_PROFILE' exists..."
# `notarytool history --keychain-profile X` is the cheapest way to assert the
# profile resolves to valid credentials. It exits non-zero with a clear error
# if the profile name is wrong or the stored Apple ID password is rejected.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    echo "error: notarytool can't authenticate with keychain profile '$NOTARY_PROFILE'." >&2
    echo "       run this once to (re-)create it (use a real Apple ID, no angle brackets):" >&2
    echo "         xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "           --apple-id you@example.com \\" >&2
    echo "           --team-id YRB6VBTSRV \\" >&2
    echo "           --password <app-specific-password from appleid.apple.com>" >&2
    echo "       (or override the profile name via NOTARY_PROFILE=...)" >&2
    exit 1
fi

echo "==> submitting archive to notarytool (streaming live; this takes 1–5 min)..."
# Stream output live AND capture exit code so a failure surfaces with full
# notarytool messaging instead of leaving the user staring at a silent prompt.
set +e
xcrun notarytool submit "$ARCHIVE_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
NOTARIZE_RC=$?
set -e
if [[ $NOTARIZE_RC -ne 0 ]]; then
    echo "" >&2
    echo "error: notarytool exited $NOTARIZE_RC. Common causes:" >&2
    echo "  - invalid Apple ID / app-specific password (re-run store-credentials)" >&2
    echo "  - signed binary missing hardened runtime or timestamp (this script sets both)" >&2
    echo "  - entitlement not registered against your Developer ID" >&2
    echo "  - Apple notarization service degraded (status.developer.apple.com)" >&2
    echo "" >&2
    echo "for a detailed validation log, take the submission ID from above and run:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

# Stapling is for .app/.dmg/.pkg. For a tar.gz of a Mach-O, distribute as-is;
# Gatekeeper checks notarization via the online ticket lookup. Verify with
# `spctl -a -v` doesn't apply to a CLI binary; instead, re-running the binary
# without quarantine confirms it works.

SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
echo ""
echo "==> done."
echo "    archive: $ARCHIVE_PATH"
echo "    sha256:  $SHA"
echo ""
echo "next steps:"
echo "  1. upload $ARCHIVE_NAME to a public URL (GitHub release asset is easiest)"
echo "  2. update your homebrew-file13 tap formula:"
echo ""
cat <<EOF
       url    "https://github.com/smbrownai/homebrew-file13/releases/download/v$VERSION/$ARCHIVE_NAME"
       sha256 "$SHA"
       version "$VERSION"
EOF
echo ""
echo "  3. \`brew update && brew upgrade --cask file13\` (or \`brew install\`)."
