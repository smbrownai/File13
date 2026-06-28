# file13 CLI

Headless companion CLI for File13. Reads and writes the same accounts,
settings, rules, AI provider keys (CLI-side), categories, VIPs, and SwiftData
header cache that the macOS `File13.app` uses, and runs IMAP operations
unattended via launchd.

Distributed as a signed + notarized standalone binary via a Homebrew tap.

## Install (end users)

```sh
brew tap smbrownai/file13
brew install file13
file13 doctor
```

`file13 doctor` should report `appGroupContainer: ok ... (write verified)`
and `appleFoundationModels: available` on a Mac with Apple Intelligence enabled.

## Develop (this directory)

The CLI is a Swift Package at `cli/Package.swift`. For day-to-day iteration:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build --package-path cli
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift run --package-path cli file13 doctor
```

Why `xcrun` and `DEVELOPER_DIR`: the system `swift` toolchain ships with
Command Line Tools, which targets an older macOS SDK. Apple Foundation
Models' public surface needs the macOS 26 SDK that comes with Xcode.

## Command surface

```
file13 version
file13 doctor                                    # capability check + diagnostics
file13 status                                    # accounts/lock/last-run summary (TODO: implement, currently part of doctor)

file13 settings list / get <key> / set …
file13 settings export <file> / import <file> [--mode merge|replace]

file13 accounts list / add / delete / test
file13 providers list [--probe] / test <provider>
file13 providers set-key <provider>              # reads from stdin
file13 providers delete-key <provider>

file13 senders list                              # address, count, unread, mostRecent
file13 refresh [--account UUID] [--mailbox X] [--full]

file13 mail delete  [SENDER-FLAGS] [--dry-run] [--yes] [--no-protect]
file13 mail archive [SENDER-FLAGS] [--dry-run] [--yes]
file13 mail move    [SENDER-FLAGS] --to <folder> [--dry-run] [--yes]

file13 rules list / show / enable / disable
file13 rules run [--dry-run] [--rule UUID] [--account UUID]
file13 rules schedule get / set / install / remove / status

file13 ai tuning get / set / unset / reset       # per-feature AI customization

file13 config export <file> / import <file>     # full round-trip, no secrets
```

`SENDER-FLAGS` (any combination, set-unioned): `--sender a,b,c`,
`--senders-file path`, stdin pipe (auto-detected), `--domain x.com`,
`--category promotional`, `--vip`, `--account UUID`, `--mailbox NAME`.

Every IMAP-touching command (`refresh`, `mail …`, `rules run`, `senders list`,
`config import`) acquires an exclusive lock on the App Group container. They
bail with exit code 2 if `File13.app` is open. Read-only commands
(`settings`, `accounts list`, `providers list`, `rules list`, `ai tuning`,
`config export`) work alongside the GUI without conflict.

## Architecture

The CLI imports the same Swift Package (`Packages/File13Core`) the GUI app
uses. Stores, AI providers, IMAP layer, models — all shared. The GUI is the
only place SwiftUI lives; everything else is in the package.

State sharing happens through:

- **App Group container** at `~/Library/Group Containers/group.com.shawnbrown.File13/`
  — UserDefaults suite (settings, accounts, rules, AI tuning), SwiftData
  store (cached headers), lock file. Both binaries hit the same paths.
- **Default user keychain** at service `com.shawnbrown.File13` — IMAP
  passwords (account `imap-password-<uuid>`) and AI provider keys (account
  `ai-key-<provider>`). The CLI manages its own entries here separately
  from the GUI; see "Credential separation" below.

## Credential separation

The CLI is signed *without* `keychain-access-groups` because that's a
restricted entitlement requiring a provisioning profile that bare CLI
binaries can't carry. Practical consequence:

- The GUI writes IMAP passwords + AI provider keys with an access-group
  attribute (`<TeamID>.com.shawnbrown.File13.shared`).
- The CLI writes them without an access-group attribute.
- Each side reads its own entries; they don't share.

Net: users running both must add accounts and set provider keys on the CLI
side independently. `file13 accounts add` and `file13 providers set-key
<provider>` both read secrets from stdin (never argv) so this is scriptable.

## Releasing

See [`RELEASE.md`](RELEASE.md) for the runbook (Apple Developer ID setup,
notarytool keychain profile, per-release flow, troubleshooting).

The release script at [`Scripts/release.sh`](Scripts/release.sh) builds,
signs, notarizes, archives as a `.zip`, and prints the formula stanza to
paste into the tap repo.
