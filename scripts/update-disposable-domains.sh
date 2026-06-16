#!/usr/bin/env bash
# Refresh the vendored disposable-email-domains blocklist used by
# `DisposableSenderDetector`. The list is CC0 public domain, updated
# upstream via PRs at github.com/disposable-email-domains/disposable-email-domains.
#
# Run this manually before each File13 release. Diff the file, commit it
# alongside the version bump.
#
# Usage:
#   scripts/update-disposable-domains.sh

set -euo pipefail

URL="https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Packages/File13Core/Sources/File13Core/Resources/disposable_email_blocklist.conf"

if [[ ! -d "$(dirname "$DEST")" ]]; then
  echo "Resources directory not found at $(dirname "$DEST")" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Fetching $URL"
curl -fsSL "$URL" -o "$TMP"

# Sanity check: the file should be plain ASCII-ish domain-per-line, several
# thousand lines, no HTML/JSON. Bail loudly if the upstream changed shape.
LINES=$(wc -l < "$TMP" | tr -d ' ')
if [[ "$LINES" -lt 1000 ]]; then
  echo "Refusing to install: only $LINES lines in fetched file (expected several thousand)." >&2
  exit 1
fi
if grep -q '<\|{' "$TMP"; then
  echo "Refusing to install: fetched file contains HTML/JSON markers." >&2
  exit 1
fi

mv "$TMP" "$DEST"
echo "Wrote $DEST ($LINES domains)"
echo "Diff against previous version:"
git -C "$(dirname "$DEST")" diff --stat -- "$DEST" || true
