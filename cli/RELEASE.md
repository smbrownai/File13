# Releasing the file13 CLI

End-to-end runbook for cutting a versioned release: build, sign, notarize, ship
via Homebrew tap.

## One-time setup

You only do these once per machine / Apple Developer account.

### 1. Apple Developer ID Application certificate

You need a "Developer ID Application" certificate in the user keychain that
codesign can find. Two paths:

**From Xcode:** Xcode → Settings → Accounts → select your Apple ID →
Manage Certificates → **+** → "Developer ID Application". Xcode generates the
cert + private key and installs them in your login keychain.

**From the Apple Developer portal:** create a CSR with Keychain Access
(Keychain Access → Certificate Assistant → "Request a Certificate from a
Certificate Authority…"), upload it at developer.apple.com → Certificates → +,
download the `.cer`, double-click to install.

Verify it's there:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The exact name (e.g. `Developer ID Application: Shawn Brown (YRB6VBTSRV)`)
is what you pass as `DEVELOPER_ID` to the release script.

### 2. App-specific password for notarytool

Apple notarization needs API credentials. Easiest path: an app-specific
password tied to your Apple ID.

1. Sign in at https://appleid.apple.com/account/manage
2. Sign-In and Security → App-Specific Passwords → Generate.
3. Copy the password. Apple won't show it again.

Store it in the keychain via notarytool so future runs don't prompt:

```sh
xcrun notarytool store-credentials file13-notary \
  --apple-id <your-apple-id> \
  --team-id YRB6VBTSRV \
  --password <the-app-specific-password-you-just-made>
```

The script defaults to keychain profile name `file13-notary`. Override with
`NOTARY_PROFILE=<name>` if you used something else.

### 3. Entitlements (intentionally none)

The CLI signs **without** any entitlements claim. An earlier attempt to mirror
the GUI's App Group + Keychain Access Group entitlements failed at runtime —
amfid kills binaries that claim restricted entitlements without a backing
provisioning profile. App bundles carry one; bare CLI binaries don't.

Real-world consequence: the CLI manages its own Keychain entries in the
default user keychain (no access group), so it does **not** see IMAP
passwords or AI provider keys the GUI app stored. Users running both must
add accounts and provider keys on the CLI side independently.

The CLI **does** still see settings, rules, sender categories, VIPs, and the
SwiftData header cache, because those live in the App Group container as
plain filesystem paths that any process owned by the user can read.

### 4. Homebrew tap repo

Create a public GitHub repo named exactly `homebrew-file13` (the
`homebrew-` prefix is required — `brew tap smbrownai/file13` looks for that
naming convention).

```sh
gh repo create smbrownai/homebrew-file13 --public --description "Homebrew tap for file13"
git clone https://github.com/smbrownai/homebrew-file13.git
cd homebrew-file13
mkdir Formula
cp /path/to/file13/cli/Formula/file13.rb Formula/
git add Formula/file13.rb
git commit -m "Initial formula"
git push
```

End users install with:

```sh
brew tap smbrownai/file13
brew install file13
```

## Per-release flow

For each release after the first one:

### 1. Bump the version constant

Edit `cli/Sources/file13/File13.swift`:

```swift
let file13Version = "0.1.0"   // bump
```

The release script aborts if the binary's self-reported version doesn't match
what you pass on the command line — this is a deliberate gate so you can't
ship a binary tagged as `0.1.0` that says `0.0.1-dev`.

### 2. Tag and push the source

```sh
git commit -am "file13 0.1.0"
git tag -s v0.1.0    # signed tag if you have GPG set up; or `git tag v0.1.0`
git push origin main v0.1.0
```

### 3. Run the release script

```sh
export DEVELOPER_ID="Developer ID Application: Shawn Brown (YRB6VBTSRV)"
cli/Scripts/release.sh 0.1.0
```

What it does:
1. `swift build -c release` (arm64-apple-macosx26.0)
2. Verifies the built binary self-reports `0.1.0`
3. `codesign` with `--options runtime` (hardened runtime) + `--timestamp` +
   `--sign "$DEVELOPER_ID"` (no entitlements — see §3 above for why)
4. Verifies signature + entitlements
5. Stages binary + README into `cli/.build/dist/file13-0.1.0/`
6. zips to `cli/.build/dist/file13-0.1.0-arm64-macos.zip` via `ditto`
   (notarytool only accepts .zip / .pkg / .dmg)
7. Submits to `notarytool`, **waits**, asserts status is `Accepted`
8. Prints SHA256 and a copy-pasteable Homebrew formula stanza

The whole run takes 2–8 minutes depending on Apple's notarization queue.

### 4. Upload the archive to the GitHub release

```sh
gh release create v0.1.0 \
  --title "file13 0.1.0" \
  --notes "..." \
  cli/.build/dist/file13-0.1.0-arm64-macos.zip
```

Or upload it manually via the GitHub web UI.

### 5. Update the tap formula

In `homebrew-file13/Formula/file13.rb`, update the three lines printed at
the end of the release script:

```ruby
version "0.1.0"
on_macos do
  on_arm do
    url    "https://github.com/smbrownai/file13/releases/download/v0.1.0/file13-0.1.0-arm64-macos.zip"
    sha256 "<the SHA the script printed>"
  end
end
```

Commit + push to the tap repo. Within seconds, every user with `file13`
installed can `brew update && brew upgrade file13`.

## Why no stapling

`xcrun stapler staple` only works on `.app`, `.pkg`, and `.dmg`. A bare
Mach-O CLI binary (or a `.zip` of one) can't be stapled. Gatekeeper still
verifies notarization on first run via online lookup — works fine for any user
with internet, which is the entire target audience for an IMAP CLI.

If you ever want offline-first / airgap-safe distribution, wrap the binary in
a `.pkg` installer with `pkgbuild`, then `productsign` + `notarytool` + staple.
That path is explicitly out of scope here.

## Troubleshooting

### `notarytool submit … --wait` returns `status: Invalid`

Run `xcrun notarytool log <submission-id> --keychain-profile file13-notary`
to see the validation log. Common causes:

- **Hardened runtime missing**: rerun `codesign` with `--options runtime`.
  The release script already sets this; only an issue if you re-sign manually.
- **Timestamp missing**: `--timestamp` flag on codesign.
- **Entitlement not allowed by your Developer ID**: register the missing
  entitlement (App Group, Keychain Sharing, etc.) in developer.apple.com.

### `codesign: errSecInternalComponent`

The Developer ID private key in your keychain is locked or the keychain
password has changed since the cert was created. Open Keychain Access, find
the private key, right-click → Get Info → Access Control → "Allow all
applications to access this item" (or specifically allow `codesign`).

### CLI installs but `file13 doctor` reports "entitlement likely missing"

Either the Homebrew tap's `sha256` is stale (the user is running a different
binary than the one you signed) or the .zip got repacked in flight (rare
on GitHub releases). Re-run the release script and update the formula.

### The File13.app `File13` Team ID doesn't match the CLI's

Both binaries must be signed by the same Team ID. The keychain access group's
team-id prefix is resolved at signing — a CLI signed by Team A trying to
read a keychain item written by Team B's GUI will silently get nothing back.
